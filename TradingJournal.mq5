//+------------------------------------------------------------------+
//|  TradingJournal.mq5                                              |
//|  Pushes this terminal's activity to a Trading Journal workspace.  |
//+------------------------------------------------------------------+
//
//  WHY THIS EXISTS
//
//  MetaTrader has no public HTTP API, so a journal that syncs "server side"
//  has to either hold the trader's investor password with a paid third party,
//  or run a Windows terminal on somebody else's infrastructure. This EA is the
//  alternative: it runs on YOUR terminal and posts what it already sees. The
//  key it authenticates with can do nothing except write into one journal --
//  it cannot read the journal back, cannot place an order, and cannot reach
//  your broker.
//
//  WHAT IT SENDS, AND THE ONE THING ONLY IT CAN SEND
//
//  Closed deals and open positions can be reconstructed from a statement.
//  The indicator values AT THE MOMENT AN ORDER WENT IN cannot: read an hour
//  later they are different numbers. Without them, a rule like "only add grid
//  levels when ADX is below 20" can never be scored, and a journal that scores
//  it anyway is lying to you.
//
//  So the snapshot is taken in OnTradeTransaction, the instant the deal is
//  reported -- not on the next timer tick -- and pushed immediately.
//
//  SETUP
//
//  1. Tools > Options > Expert Advisors > "Allow WebRequest for listed URL",
//     and add your journal's address exactly as you entered it below.
//  2. Create an ingest key in the app (Accounts > your account > Connect
//     terminal) and paste it into ApiKey.
//  3. Drop this EA on ONE chart. It covers the whole account, not one symbol,
//     so a second copy is not needed and only doubles the traffic.
//
//  Trading is never affected: this EA places no orders and holds no locks.
//
#property copyright "Trading Journal"
#property version   "1.00"
#property description "Sends this account's deals, open positions and account"
#property description "state to your Trading Journal workspace. Places no orders."

input string   ApiUrl        = "https://tradingjournal.lsys.online"; // Journal address
input string   ApiKey        = "";                            // Ingest key (tjk_...)
input int      PushSeconds   = 60;                            // Seconds between pushes
input bool     SendHistory   = true;                          // Backfill history on first run
input int      HistoryDays   = 365;                           // How far back to backfill
input ENUM_TIMEFRAMES SnapTimeframe = PERIOD_M15;             // Timeframe for entry snapshots
input int      AdxPeriod     = 14;                            // ADX period
input int      StochK        = 5;                             // Stochastic %K
input int      StochD        = 3;                             // Stochastic %D
input int      StochSlow     = 3;                             // Stochastic slowing
input int      RsiPeriod     = 14;                            // RSI period
input int      AtrPeriod     = 14;                            // ATR period
input int      MaFast        = 20;                            // Fast MA period
input int      MaSlow        = 50;                            // Slow MA period
input bool     Verbose       = false;                         // Log every push

#define EA_VERSION "1.00"

// Entry snapshots waiting to be sent, keyed by position ticket.
//
// Kept in memory AND re-sent on every push until the position closes. The
// server writes them once and ignores the rest, so re-sending is free and
// means a push that fails costs nothing: the next one carries the same data.
struct EntrySnap
{
   ulong  position;
   string symbol;
   double adx, stoch_k, stoch_d, rsi, atr_points, spread_points, ma_fast, ma_slow;
   double balance, equity, margin_level;
   int    open_positions;
   bool   valid;
};

EntrySnap g_snaps[];

// One set of indicator handles per symbol, created on first use and kept for
// the life of the EA. Declared here rather than beside HandlesFor() because a
// global has to precede the first function that reads it.
struct SymbolHandles
{
   string symbol;
   int    adx, stoch, rsi, atr, ma_fast, ma_slow;
};

SymbolHandles g_handles[];
long      g_last_ticket   = 0;     // highest deal ticket the journal already holds
bool      g_backfilled    = false;
bool      g_warned_webreq = false;
datetime  g_last_push     = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(ApiKey) < 8)
   {
      Print("TradingJournal: no ApiKey set. Create an ingest key in the app and ",
            "paste it into the EA's inputs.");
      return(INIT_FAILED);
   }
   if(StringFind(ApiUrl, "http") != 0)
   {
      Print("TradingJournal: ApiUrl must start with http:// or https://");
      return(INIT_FAILED);
   }

   ArrayResize(g_snaps, 0);

   // Say hello before sending anything. A wrong key or a URL that was never
   // allowed in Tools > Options then shows up as one clear line in the Experts
   // log, instead of as a push that silently fails every minute.
   string resp;
   int code = Post("/api/v1/ingest/hello", "{}", resp);
   if(code == 401)
   {
      Print("TradingJournal: that ingest key was refused. Create a new one in the app.");
      return(INIT_FAILED);
   }
   if(code <= 0)
   {
      Print("TradingJournal: could not reach ", ApiUrl, ". Add it under ",
            "Tools > Options > Expert Advisors > Allow WebRequest for listed URL.");
      return(INIT_FAILED);
   }
   if(code >= 300)
   {
      Print("TradingJournal: the journal answered ", code, ": ", resp);
      return(INIT_FAILED);
   }

   g_last_ticket = (long)JsonNumber(resp, "lastTicket");
   PrintFormat("TradingJournal %s connected. The journal holds deals up to ticket %I64d.",
               EA_VERSION, g_last_ticket);

   EventSetTimer(MathMax(10, PushSeconds));
   // The first push happens straight away rather than after a minute, so a
   // trader who has just installed this sees something immediately.
   Push(SendHistory && !g_backfilled);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ReleaseHandles();
   // One last push on the way out: a terminal being closed for the night
   // should not lose the last minute of a basket that is still open.
   if(reason != REASON_INITFAILED)
      Push(false);
}

void OnTimer()
{
   Push(SendHistory && !g_backfilled);
}

//+------------------------------------------------------------------+
//| The reason this EA is worth installing.                          |
//|                                                                  |
//| A new position's indicator values are captured HERE, when the     |
//| deal is reported, and pushed immediately. Waiting for the timer   |
//| would mean recording the chart as it looked up to a minute after  |
//| the entry -- and on gold in a fast market that is a different     |
//| market.                                                          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.deal_type != DEAL_TYPE_BUY && trans.deal_type != DEAL_TYPE_SELL)
      return;

   // Only an opening deal starts a position. DEAL_ENTRY is not a field on
   // MqlTradeTransaction, so it is read from the history record for this deal.
   if(!HistoryDealSelect(trans.deal))
      return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_INOUT)
      return;

   ulong pos = trans.position;
   if(pos == 0)
      return;
   if(FindSnap(pos) >= 0)
      return;

   EntrySnap s;
   if(!Capture(trans.symbol, pos, s))
      return;

   int n = ArraySize(g_snaps);
   ArrayResize(g_snaps, n + 1);
   g_snaps[n] = s;

   if(Verbose)
      PrintFormat("TradingJournal: captured entry for #%I64u %s ADX=%.1f K=%.1f",
                  pos, trans.symbol, s.adx, s.stoch_k);

   // Straight out, without waiting for the timer. If the terminal is closed
   // before the next tick, the snapshot would otherwise be lost -- and it is
   // the one thing that cannot be recovered later from any other source.
   Push(false);
}

//+------------------------------------------------------------------+
//| Reading the chart.                                               |
//|                                                                  |
//| Indicator handles are created, read and released per call. That   |
//| is deliberately wasteful: holding handles for every symbol a grid |
//| might touch leaks them over a long run, and this happens at most  |
//| once per order.                                                   |
//+------------------------------------------------------------------+
bool Capture(const string symbol, const ulong position, EntrySnap &s)
{
   s.valid          = false;
   s.position       = position;
   s.symbol         = symbol;
   s.adx            = EMPTY_VALUE;
   s.stoch_k        = EMPTY_VALUE;
   s.stoch_d        = EMPTY_VALUE;
   s.rsi            = EMPTY_VALUE;
   s.atr_points     = EMPTY_VALUE;
   s.ma_fast        = EMPTY_VALUE;
   s.ma_slow        = EMPTY_VALUE;
   s.spread_points  = (double)SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   s.balance        = AccountInfoDouble(ACCOUNT_BALANCE);
   s.equity         = AccountInfoDouble(ACCOUNT_EQUITY);
   s.margin_level   = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   s.open_positions = PositionsTotal();

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0)
      point = 1;

   int h = HandlesFor(symbol);
   if(h < 0)
      return(false);

   s.adx       = ReadOne(g_handles[h].adx, 0);
   s.stoch_k   = ReadOne(g_handles[h].stoch, 0);
   s.stoch_d   = ReadOne(g_handles[h].stoch, 1);
   s.rsi       = ReadOne(g_handles[h].rsi, 0);

   double atr  = ReadOne(g_handles[h].atr, 0);
   if(atr != EMPTY_VALUE)
      s.atr_points = atr / point;   // points, so a rule reads the same on any broker

   s.ma_fast = ReadOne(g_handles[h].ma_fast, 0);
   s.ma_slow = ReadOne(g_handles[h].ma_slow, 0);

   s.valid = true;
   return(true);
}

// ReadOne pulls one buffer value, retrying briefly.
//
// The retry is not defensive padding. A handle MetaTrader has only just created
// -- the first order ever placed on a symbol -- answers CopyBuffer with nothing
// until it has calculated, and this value is the one thing in the whole product
// that cannot be recovered afterwards from any other source. Half a second of
// waiting at the moment an order goes in is a fair price for it.
//
// Returns EMPTY_VALUE when it genuinely cannot be read, which the JSON writer
// then OMITS -- so the journal records "not scored" rather than a zero that was
// never measured.
double ReadOne(const int handle, const int buffer)
{
   if(handle == INVALID_HANDLE)
      return(EMPTY_VALUE);
   double v[];
   for(int attempt = 0; attempt < 10; attempt++)
   {
      if(CopyBuffer(handle, buffer, 0, 1, v) >= 1 &&
         v[0] != EMPTY_VALUE && MathIsValidNumber(v[0]))
         return(v[0]);
      Sleep(50);
   }
   return(EMPTY_VALUE);
}

//+------------------------------------------------------------------+
//| Indicator handles, one set per symbol, created once and kept.     |
//|                                                                  |
//| A grid account may touch several symbols, and creating six        |
//| handles per order would both leak them over a long run and hit    |
//| the not-yet-calculated race above on every single entry.          |
//+------------------------------------------------------------------+
int HandlesFor(const string symbol)
{
   for(int i = 0; i < ArraySize(g_handles); i++)
      if(g_handles[i].symbol == symbol)
         return(i);

   SymbolHandles h;
   h.symbol  = symbol;
   h.adx     = iADX(symbol, SnapTimeframe, AdxPeriod);
   h.stoch   = iStochastic(symbol, SnapTimeframe, StochK, StochD, StochSlow,
                           MODE_SMA, STO_LOWHIGH);
   h.rsi     = iRSI(symbol, SnapTimeframe, RsiPeriod, PRICE_CLOSE);
   h.atr     = iATR(symbol, SnapTimeframe, AtrPeriod);
   h.ma_fast = iMA(symbol, SnapTimeframe, MaFast, 0, MODE_EMA, PRICE_CLOSE);
   h.ma_slow = iMA(symbol, SnapTimeframe, MaSlow, 0, MODE_EMA, PRICE_CLOSE);

   if(h.adx == INVALID_HANDLE)
   {
      PrintFormat("TradingJournal: could not create indicators for %s (error %d). "
                  "Entry rules will show as not scored for it.",
                  symbol, GetLastError());
      return(-1);
   }

   int n = ArraySize(g_handles);
   ArrayResize(g_handles, n + 1);
   g_handles[n] = h;
   return(n);
}

void ReleaseHandles()
{
   for(int i = 0; i < ArraySize(g_handles); i++)
   {
      IndicatorRelease(g_handles[i].adx);
      IndicatorRelease(g_handles[i].stoch);
      IndicatorRelease(g_handles[i].rsi);
      IndicatorRelease(g_handles[i].atr);
      IndicatorRelease(g_handles[i].ma_fast);
      IndicatorRelease(g_handles[i].ma_slow);
   }
   ArrayResize(g_handles, 0);
}

int FindSnap(const ulong position)
{
   for(int i = 0; i < ArraySize(g_snaps); i++)
      if(g_snaps[i].position == position)
         return(i);
   return(-1);
}

// Snapshots for positions that no longer exist are dropped, so a terminal left
// running for months does not grow this array without limit.
void PruneSnaps()
{
   int n = ArraySize(g_snaps);
   for(int i = n - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(g_snaps[i].position))
      {
         for(int j = i; j < ArraySize(g_snaps) - 1; j++)
            g_snaps[j] = g_snaps[j + 1];
         ArrayResize(g_snaps, ArraySize(g_snaps) - 1);
      }
   }
}

//+------------------------------------------------------------------+
//| The push.                                                        |
//+------------------------------------------------------------------+
void Push(const bool backfill)
{
   string body = BuildBody(backfill);
   string resp;
   int code = Post("/api/v1/ingest/sync", body, resp);

   if(code == 401)
   {
      Print("TradingJournal: the ingest key was refused. It may have been revoked.");
      return;
   }
   if(code == 429)
   {
      // The journal is asking for less. Not an error worth shouting about.
      if(Verbose) Print("TradingJournal: asked to slow down.");
      return;
   }
   if(code <= 0)
   {
      Print("TradingJournal: push failed to reach ", ApiUrl,
            " (is it still allowed under Tools > Options?)");
      return;
   }
   if(code >= 300)
   {
      Print("TradingJournal: push rejected (", code, "): ", StringSubstr(resp, 0, 300));
      return;
   }

   // The journal reports the highest ticket it now holds, so the next push
   // starts from there. Taking this from the response rather than tracking it
   // locally means a terminal that was reinstalled, or moved to another
   // machine, catches up on its own with nothing to configure.
   long reported = (long)JsonNumber(resp, "lastTicket");
   if(reported > g_last_ticket)
      g_last_ticket = reported;

   if(backfill)
   {
      g_backfilled = true;
      PrintFormat("TradingJournal: history sent (%d deals accepted, %d already held).",
                  (int)JsonNumber(resp, "dealsInserted"),
                  (int)JsonNumber(resp, "dealsDuplicate"));
   }
   else if(Verbose)
   {
      PrintFormat("TradingJournal: +%d deals, %d positions, %d alerts",
                  (int)JsonNumber(resp, "dealsInserted"),
                  (int)JsonNumber(resp, "positions"),
                  (int)JsonNumber(resp, "alerts"));
   }
   g_last_push = TimeCurrent();
   PruneSnaps();
}

string BuildBody(const bool backfill)
{
   string s = "{";
   s += "\"backfill\":" + (backfill ? "true" : "false") + ",";
   s += "\"snapshot\":" + SnapshotJson() + ",";
   s += "\"symbols\":" + SymbolsJson() + ",";
   s += "\"positions\":" + PositionsJson() + ",";
   s += "\"deals\":" + DealsJson(backfill);
   s += "}";
   return(s);
}

//+------------------------------------------------------------------+
//| Times are sent as two unix integers, never as formatted strings. |
//|                                                                  |
//|   t  = TimeGMT()     the true instant                            |
//|   st = TimeCurrent() the broker's own clock                      |
//|                                                                  |
//| Their difference IS the server's offset, so the journal measures  |
//| it instead of being told -- and follows a broker that moves to    |
//| summer time without anybody editing a setting. A formatted local  |
//| string would be the single most reliable way to be five hours     |
//| wrong about every session statistic in the journal.               |
//+------------------------------------------------------------------+
string SnapshotJson()
{
   string s = "{";
   s += "\"login\":\"" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "\",";
   s += "\"server\":" + JsonStr(AccountInfoString(ACCOUNT_SERVER)) + ",";
   s += "\"company\":" + JsonStr(AccountInfoString(ACCOUNT_COMPANY)) + ",";
   s += "\"currency\":" + JsonStr(AccountInfoString(ACCOUNT_CURRENCY)) + ",";
   s += "\"leverage\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)) + ",";
   s += "\"balance\":" + Num(AccountInfoDouble(ACCOUNT_BALANCE)) + ",";
   s += "\"equity\":" + Num(AccountInfoDouble(ACCOUNT_EQUITY)) + ",";
   s += "\"margin\":" + Num(AccountInfoDouble(ACCOUNT_MARGIN)) + ",";
   s += "\"freeMargin\":" + Num(AccountInfoDouble(ACCOUNT_MARGIN_FREE)) + ",";
   s += "\"marginLevel\":" + Num(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL)) + ",";
   s += "\"t\":" + IntegerToString((long)TimeGMT()) + ",";
   s += "\"st\":" + IntegerToString((long)TimeCurrent()) + ",";
   s += "\"ea\":\"" + EA_VERSION + "\"";
   s += "}";
   return(s);
}

// The digits and tick value of every symbol currently in the market, so the
// journal can turn a price difference into points and points into money. It
// cannot guess these: gold is 2 digits at one broker and 3 at the next.
string SymbolsJson()
{
   string seen[];
   string out = "[";
   int written = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionGetTicket(i))
         continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      bool dup = false;
      for(int j = 0; j < ArraySize(seen); j++)
         if(seen[j] == sym) { dup = true; break; }
      if(dup)
         continue;
      int n = ArraySize(seen);
      ArrayResize(seen, n + 1);
      seen[n] = sym;

      if(written > 0) out += ",";
      out += "{";
      out += "\"symbol\":" + JsonStr(sym) + ",";
      out += "\"digits\":" + IntegerToString(SymbolInfoInteger(sym, SYMBOL_DIGITS)) + ",";
      out += "\"point\":" + Num(SymbolInfoDouble(sym, SYMBOL_POINT)) + ",";
      out += "\"contractSize\":" + Num(SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE)) + ",";
      out += "\"tickValue\":" + Num(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE));
      out += "}";
      written++;
   }
   out += "]";
   return(out);
}

string PositionsJson()
{
   string out = "[";
   int written = 0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(written > 0) out += ",";
      string sym = PositionGetString(POSITION_SYMBOL);
      out += "{";
      out += "\"ticket\":" + IntegerToString((long)ticket) + ",";
      out += "\"symbol\":" + JsonStr(sym) + ",";
      out += "\"type\":\"" +
             (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell") + "\",";
      out += "\"volume\":" + Num(PositionGetDouble(POSITION_VOLUME)) + ",";
      out += "\"openPrice\":" + Num(PositionGetDouble(POSITION_PRICE_OPEN)) + ",";
      out += "\"sl\":" + Num(PositionGetDouble(POSITION_SL)) + ",";
      out += "\"tp\":" + Num(PositionGetDouble(POSITION_TP)) + ",";
      // While the position is open these are the UNREALISED amounts. The
      // journal uses them to track how far under water a basket gets, which is
      // the one number a closed-trade history can never recover.
      out += "\"profit\":" + Num(PositionGetDouble(POSITION_PROFIT)) + ",";
      out += "\"swap\":" + Num(PositionGetDouble(POSITION_SWAP)) + ",";
      out += "\"commission\":0,";
      out += "\"magic\":" + IntegerToString(PositionGetInteger(POSITION_MAGIC)) + ",";
      out += "\"t\":" + IntegerToString(PositionGetInteger(POSITION_TIME)) + ",";
      out += "\"st\":" + IntegerToString(PositionGetInteger(POSITION_TIME));

      int si = FindSnap(ticket);
      if(si >= 0 && g_snaps[si].valid)
         out += ",\"entry\":" + SnapJson(g_snaps[si]);

      out += "}";
      written++;
   }
   out += "]";
   return(out);
}

// Absent values are OMITTED rather than sent as zero. A rule scored against an
// ADX of zero that was never measured would read as "kept" every time.
string SnapJson(const EntrySnap &s)
{
   string out = "{";
   out += "\"tf\":" + JsonStr(TfName(SnapTimeframe));
   out += Opt("adx", s.adx);
   out += Opt("stochK", s.stoch_k);
   out += Opt("stochD", s.stoch_d);
   out += Opt("rsi", s.rsi);
   out += Opt("atrPoints", s.atr_points);
   out += Opt("spreadPoints", s.spread_points);
   out += Opt("maFast", s.ma_fast);
   out += Opt("maSlow", s.ma_slow);
   out += Opt("balance", s.balance);
   out += Opt("equity", s.equity);
   out += Opt("marginLevel", s.margin_level);
   out += ",\"openPositions\":" + IntegerToString(s.open_positions);
   out += "}";
   return(out);
}

string Opt(const string key, const double v)
{
   if(v == EMPTY_VALUE || !MathIsValidNumber(v))
      return("");
   return(",\"" + key + "\":" + Num(v));
}

//+------------------------------------------------------------------+
//| Deals.                                                           |
//|                                                                  |
//| An ordinary push sends a WINDOW ending at the newest deal, not    |
//| strictly what is new. Re-sending is free -- the journal keys on   |
//| the broker's own deal ticket and ignores duplicates -- and it     |
//| means a lost response, a restart or a clock change costs nothing. |
//| Making the EA responsible for remembering what it had already     |
//| sent would be the fragile half of this design.                   |
//+------------------------------------------------------------------+
string DealsJson(const bool backfill)
{
   datetime from = TimeCurrent() - 7 * 24 * 60 * 60;
   if(backfill)
      from = TimeCurrent() - (datetime)(MathMax(1, HistoryDays) * 24 * 60 * 60);

   if(!HistorySelect(from, TimeCurrent() + 24 * 60 * 60))
      return("[]");

   string out = "[";
   int written = 0;
   int total = HistoryDealsTotal();

   // Newest first, and capped. A year of a busy grid account is tens of
   // thousands of deals; sending them in slices keeps each request a size the
   // terminal can actually build and the journal can actually read, and the
   // next push simply carries the next slice.
   int cap = backfill ? 3000 : 400;

   for(int i = total - 1; i >= 0 && written < cap; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      long deal_ticket = (long)ticket;
      // On an ordinary push, skip what the journal already holds. On a
      // backfill, send everything in the window: the journal may hold recent
      // deals and none of the old ones.
      if(!backfill && deal_ticket <= g_last_ticket)
         continue;

      if(written > 0) out += ",";
      out += "{";
      out += "\"ticket\":" + IntegerToString(deal_ticket) + ",";
      out += "\"order\":" + IntegerToString(HistoryDealGetInteger(ticket, DEAL_ORDER)) + ",";
      out += "\"position\":" + IntegerToString(HistoryDealGetInteger(ticket, DEAL_POSITION_ID)) + ",";
      out += "\"symbol\":" + JsonStr(HistoryDealGetString(ticket, DEAL_SYMBOL)) + ",";
      out += "\"type\":\"" + DealTypeName((int)HistoryDealGetInteger(ticket, DEAL_TYPE)) + "\",";
      out += "\"entry\":\"" + EntryName((int)HistoryDealGetInteger(ticket, DEAL_ENTRY)) + "\",";
      out += "\"volume\":" + Num(HistoryDealGetDouble(ticket, DEAL_VOLUME)) + ",";
      out += "\"price\":" + Num(HistoryDealGetDouble(ticket, DEAL_PRICE)) + ",";
      out += "\"profit\":" + Num(HistoryDealGetDouble(ticket, DEAL_PROFIT)) + ",";
      out += "\"commission\":" + Num(HistoryDealGetDouble(ticket, DEAL_COMMISSION)) + ",";
      out += "\"swap\":" + Num(HistoryDealGetDouble(ticket, DEAL_SWAP)) + ",";
      out += "\"fee\":" + Num(HistoryDealGetDouble(ticket, DEAL_FEE)) + ",";
      out += "\"magic\":" + IntegerToString(HistoryDealGetInteger(ticket, DEAL_MAGIC)) + ",";
      out += "\"reason\":\"" + ReasonName((int)HistoryDealGetInteger(ticket, DEAL_REASON)) + "\",";
      out += "\"comment\":" + JsonStr(HistoryDealGetString(ticket, DEAL_COMMENT)) + ",";
      // DEAL_TIME is the broker's clock. Both forms are sent so the journal can
      // keep the trader's own view and the true instant apart.
      long st = HistoryDealGetInteger(ticket, DEAL_TIME);
      long offset = (long)TimeCurrent() - (long)TimeGMT();
      out += "\"st\":" + IntegerToString(st) + ",";
      out += "\"t\":" + IntegerToString(st - offset);
      out += "}";
      written++;
   }
   out += "]";
   return(out);
}

string DealTypeName(const int t)
{
   switch(t)
   {
      case DEAL_TYPE_BUY:                      return("buy");
      case DEAL_TYPE_SELL:                     return("sell");
      case DEAL_TYPE_BALANCE:                  return("balance");
      case DEAL_TYPE_CREDIT:                   return("credit");
      case DEAL_TYPE_CHARGE:                   return("charge");
      case DEAL_TYPE_CORRECTION:               return("correction");
      case DEAL_TYPE_BONUS:                    return("bonus");
      case DEAL_TYPE_COMMISSION:               return("commission");
      case DEAL_TYPE_COMMISSION_DAILY:         return("commission_daily");
      case DEAL_TYPE_COMMISSION_MONTHLY:       return("commission_monthly");
      case DEAL_TYPE_INTEREST:                 return("interest");
      case DEAL_DIVIDEND:                      return("dividend");
      case DEAL_TAX:                           return("tax");
      default:                                 return("correction");
   }
}

string EntryName(const int e)
{
   switch(e)
   {
      case DEAL_ENTRY_IN:     return("in");
      case DEAL_ENTRY_OUT:    return("out");
      case DEAL_ENTRY_INOUT:  return("inout");
      case DEAL_ENTRY_OUT_BY: return("out_by");
      default:                return("state");
   }
}

string ReasonName(const int r)
{
   switch(r)
   {
      case DEAL_REASON_CLIENT: case DEAL_REASON_MOBILE: case DEAL_REASON_WEB:
         return("manual");
      case DEAL_REASON_EXPERT: return("expert");
      case DEAL_REASON_SL:     return("sl");
      case DEAL_REASON_TP:     return("tp");
      case DEAL_REASON_SO:     return("so");
      default:                 return("unknown");
   }
}

string TfName(const ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return("M1");
      case PERIOD_M5:  return("M5");
      case PERIOD_M15: return("M15");
      case PERIOD_M30: return("M30");
      case PERIOD_H1:  return("H1");
      case PERIOD_H4:  return("H4");
      case PERIOD_D1:  return("D1");
      default:         return("M15");
   }
}

//+------------------------------------------------------------------+
//| JSON and HTTP helpers.                                           |
//+------------------------------------------------------------------+

// Num always writes a plain decimal. DoubleToString with a fixed precision is
// used rather than the default, because MQL5's default can emit scientific
// notation for small numbers and the journal would reject the body.
string Num(const double v)
{
   if(!MathIsValidNumber(v))
      return("0");
   return(DoubleToString(v, 8));
}

string JsonStr(const string raw)
{
   string out = "\"";
   int n = StringLen(raw);
   for(int i = 0; i < n; i++)
   {
      ushort c = StringGetCharacter(raw, i);
      if(c == '"')       out += "\\\"";
      else if(c == '\\') out += "\\\\";
      else if(c == '\n') out += "\\n";
      else if(c == '\r') out += "\\r";
      else if(c == '\t') out += "\\t";
      else if(c < 32)    continue;   // control characters have no business here
      else               out += ShortToString(c);
   }
   out += "\"";
   return(out);
}

// JsonNumber reads one top-level numeric field. A full parser would be a lot of
// code for the four integers this EA ever needs back.
double JsonNumber(const string body, const string key)
{
   string needle = "\"" + key + "\":";
   int at = StringFind(body, needle);
   if(at < 0)
      return(0);
   int from = at + StringLen(needle);
   int n = StringLen(body);
   string num = "";
   for(int i = from; i < n; i++)
   {
      ushort c = StringGetCharacter(body, i);
      if((c >= '0' && c <= '9') || c == '-' || c == '.')
         num += ShortToString(c);
      else if(StringLen(num) > 0)
         break;
   }
   if(StringLen(num) == 0)
      return(0);
   return(StringToDouble(num));
}

// Post returns the HTTP status, or -1 when the request could not be made at
// all -- which in practice means the URL is not in the allowed list.
int Post(const string path, const string body, string &response)
{
   string url = ApiUrl;
   if(StringGetCharacter(url, StringLen(url) - 1) == '/')
      url = StringSubstr(url, 0, StringLen(url) - 1);
   url += path;

   char data[], result[];
   string headers = "Content-Type: application/json\r\n"
                    "X-TJ-Key: " + ApiKey + "\r\n";
   string result_headers;

   StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   // StringToCharArray appends a terminating zero, which would be sent as part
   // of the body and make the JSON invalid.
   int len = ArraySize(data) - 1;
   if(len < 0) len = 0;
   ArrayResize(data, len);

   ResetLastError();
   int code = WebRequest("POST", url, headers, 30000, data, result, result_headers);
   if(code == -1)
   {
      if(!g_warned_webreq)
      {
         PrintFormat("TradingJournal: WebRequest refused (error %d). Add %s under "
                     "Tools > Options > Expert Advisors > Allow WebRequest for listed URL.",
                     GetLastError(), ApiUrl);
         g_warned_webreq = true;
      }
      response = "";
      return(-1);
   }
   response = CharArrayToString(result, 0, ArraySize(result), CP_UTF8);
   return(code);
}
