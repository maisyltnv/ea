//+------------------------------------------------------------------+
//| ManualTrailReverse.mq5                                           |
//| ເຈົ້າກົດ BUY/SELL ເອງ → EA ຮັບໄມ້ນັ້ນ ວາງ stop ກົງກັນຂ້າມ trail ຕາມລາຄາ;   |
//| stop ຕິດ = reverse ຕໍ່ໄປອັດຕະໂນມັດ. ບໍ່ມີໄມ້ → ລໍຖ້າກົດ.                |
//+------------------------------------------------------------------+
#property copyright "maisyltnv"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum TR_SIDE { TR_BUY = 0, TR_SELL = 1 };

input double  IncreaseLot           = 0.0;     // ເພີ່ມ lot ທຸກຄັ້ງທີ່ reverse (0 = ຄົງທີ່ = lot ທີ່ກົດ)
input int     ReverseDistancePoints = 200;     // ຫ່າງ stop reverse ຈາກລາຄາ (ຈຸດ)
input int     TrailStepPoints       = 10;      // ຍ້າຍ stop ເມື່ອຕ່າງ >= ຈຸດນີ້
input double  DailyProfitTargetUSD  = 50;      // ກຳໄລຕໍ່ມື້ → ປິດໝົດ ຢຸດຮອດມື້ໃໝ່ (0 = ປິດ)
input double  DailyLossLimitUSD     = 200;     // ຂາດທຶນຕໍ່ມື້ → ປິດໝົດ ຢຸດຮອດມື້ໃໝ່ (0 = ປິດ)
input long    MagicNumber           = 7702;    // magic ຂອງໄມ້ reverse (ໄມ້ທີ່ກົດເປັນ magic 0)
input int     SlippagePoints        = 30;

CTrade   trade;
double   g_point     = 0.0;
int      g_digits    = 0;
datetime g_stopDay   = 0;      // ມື້ທີ່ຢຸດແລ້ວ (0 = ຍັງເທຣດ)
ulong    g_chain     = 0;      // ticket ໄມ້ magic-0 ທີ່ຮັບມາ (0 = ບໍ່ມີ)
datetime g_waitSince = 0;      // ຮັບສະເພາະໄມ້ທີ່ກົດຫຼັງເວລານີ້
ulong    g_adopted[];          // position id ທີ່ຮັບມາ (ສຳລັບຄິດກຳໄລມື້ນີ້)
string   g_gvStopDay, g_gvChain;

//+------------------------------------------------------------------+
double Norm(const double p) { return NormalizeDouble(p, g_digits); }

double NormLot(double lot)
{
   const double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (stepLot > 0) lot = MathFloor(lot / stepLot + 0.5) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return NormalizeDouble(lot, 2);
}

// ຫ່າງ stop ຕົວຈິງ — ບໍ່ນ້ອຍກວ່າ stops level ຂອງໂບຣກເກີ
int ReverseDist()
{
   const int stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return MathMax(ReverseDistancePoints, stops + 1);
}

datetime DayStart() { return iTime(_Symbol, PERIOD_D1, 0); }

bool IsAdoptedId(const ulong posId)
{
   for (int i = 0; i < ArraySize(g_adopted); i++) if (g_adopted[i] == posId) return true;
   return false;
}

void RememberAdopted(const ulong posId)
{
   if (IsAdoptedId(posId)) return;
   const int n = ArraySize(g_adopted);
   ArrayResize(g_adopted, n + 1);
   g_adopted[n] = posId;
}

//+------------------------------------------------------------------+
// ໄມ້ຂອງ chain = magic ຂອງ EA ຫຼື ໄມ້ magic-0 ທີ່ຮັບມາ (g_chain)
int MyPositions(ulong &tickets[])
{
   ArrayResize(tickets, 0);
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong tk = PositionGetTicket(i);
      if (tk == 0 || !PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      const bool mine = (PositionGetInteger(POSITION_MAGIC) == MagicNumber) || (tk == g_chain);
      if (!mine) continue;
      const int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      tickets[n] = tk;
   }
   return ArraySize(tickets);
}

// ໄມ້ magic-0 ໃໝ່ສຸດທີ່ກົດຫຼັງ g_waitSince (0 = ບໍ່ມີ)
ulong FindManualClick()
{
   ulong    best  = 0;
   datetime tBest = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong tk = PositionGetTicket(i);
      if (tk == 0 || !PositionSelectByTicket(tk)) continue;
      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if (PositionGetInteger(POSITION_MAGIC) != 0) continue;
      const datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if (t < g_waitSince) continue;
      if (best == 0 || t > tBest || (t == tBest && tk > best)) { best = tk; tBest = t; }
   }
   return best;
}

void DeleteMyPendings(const ulong keep = 0)
{
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong tk = OrderGetTicket(i);
      if (tk == 0 || tk == keep || !OrderSelect(tk)) continue;
      if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if (OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      trade.OrderDelete(tk);
   }
}

// ຊອກ pending ຂອງຂ້ອຍທີ່ເປັນປະເພດ want; ປະເພດອື່ນ/ຊ້ຳ ລຶບຖິ້ມ
ulong FindReversePending(const ENUM_ORDER_TYPE want)
{
   ulong found = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong tk = OrderGetTicket(i);
      if (tk == 0 || !OrderSelect(tk)) continue;
      if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if (OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if (found == 0 && (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == want) { found = tk; continue; }
      trade.OrderDelete(tk);
   }
   return found;
}

//+------------------------------------------------------------------+
// ກຳໄລມື້ນີ້ = ປິດແລ້ວ (deal ຂອງ magic ນີ້ ຫຼື ໄມ້ທີ່ຮັບມາ) + ລອຍຢູ່
double DailyPL()
{
   double pl = 0.0;
   const datetime from = DayStart();
   if (from > 0 && HistorySelect(from, TimeCurrent() + 60))
   {
      const int n = HistoryDealsTotal();
      for (int i = 0; i < n; i++)
      {
         const ulong d = HistoryDealGetTicket(i);
         if (d == 0) continue;
         if (HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
         const bool mine = (HistoryDealGetInteger(d, DEAL_MAGIC) == MagicNumber) ||
                           IsAdoptedId((ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID));
         if (!mine) continue;
         if ((datetime)HistoryDealGetInteger(d, DEAL_TIME) < from) continue;
         pl += HistoryDealGetDouble(d, DEAL_PROFIT)
             + HistoryDealGetDouble(d, DEAL_SWAP)
             + HistoryDealGetDouble(d, DEAL_COMMISSION);
      }
   }
   ulong pos[];
   const int n = MyPositions(pos);
   for (int i = 0; i < n; i++)
      if (PositionSelectByTicket(pos[i]))
         pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   return pl;
}

void CloseAll()
{
   ulong pos[];
   const int n = MyPositions(pos);
   for (int i = 0; i < n; i++) trade.PositionClose(pos[i]);
   DeleteMyPendings();
}

void SetChain(const ulong tk)
{
   g_chain = tk;
   if (tk == 0) GlobalVariableDel(g_gvChain);
   else         GlobalVariableSet(g_gvChain, (double)tk);
}

//+------------------------------------------------------------------+
// ວາງ stop ກົງກັນຂ້າມ ຫ່າງ ReverseDist ຈາກລາຄາປະຈຸບັນ
bool PlaceReverse(const TR_SIDE posSide, const double lot)
{
   const double dist = ReverseDist() * g_point;
   bool ok;
   if (posSide == TR_BUY)
   {
      const double p = Norm(SymbolInfoDouble(_Symbol, SYMBOL_BID) - dist);
      ok = trade.SellStop(lot, p, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "MTR reverse");
   }
   else
   {
      const double p = Norm(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + dist);
      ok = trade.BuyStop(lot, p, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "MTR reverse");
   }
   if (!ok) Print("Place reverse failed: ", trade.ResultRetcodeDescription());
   return ok;
}

// ຍ້າຍ stop ຕາມລາຄາ ທິດດຽວ ເມື່ອຕ່າງ >= TrailStepPoints
void TrailReverse(const ulong pend, const TR_SIDE posSide)
{
   if (!OrderSelect(pend)) return;
   const double cur  = OrderGetDouble(ORDER_PRICE_OPEN);
   const double dist = ReverseDist() * g_point;
   const double step = MathMax(1, TrailStepPoints) * g_point;
   double want;
   if (posSide == TR_BUY)
   {
      want = Norm(SymbolInfoDouble(_Symbol, SYMBOL_BID) - dist);
      if (want - cur < step) return;          // ຂຶ້ນເທົ່ານັ້ນ
   }
   else
   {
      want = Norm(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + dist);
      if (cur - want < step) return;          // ລົງເທົ່ານັ້ນ
   }
   if (!trade.OrderModify(pend, want, 0.0, 0.0, ORDER_TIME_GTC, 0))
      Print("Trail modify failed: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void Process()
{
   const datetime day = DayStart();
   if (day == 0) return;

   // ມື້ໃໝ່ → ປົດຢຸດ
   if (g_stopDay != 0 && g_stopDay != day)
   {
      g_stopDay = 0;
      GlobalVariableDel(g_gvStopDay);
      g_waitSince = TimeCurrent();
   }
   if (g_stopDay != 0) return;

   // ເປົ້າ/ຂີດຈຳກັດຕໍ່ມື້
   const double pl = DailyPL();
   if ((DailyProfitTargetUSD > 0 && pl >= DailyProfitTargetUSD) ||
       (DailyLossLimitUSD   > 0 && pl <= -DailyLossLimitUSD))
   {
      CloseAll();
      SetChain(0);
      g_stopDay = day;
      GlobalVariableSet(g_gvStopDay, (double)day);
      Print("Daily ", (pl > 0 ? "target" : "loss limit"), " hit: ", DoubleToString(pl, 2), " USD — stop until next day");
      return;
   }

   ulong pos[];
   int n = MyPositions(pos);

   // stop ຫາກໍຕິດ → ມີ 2 ໄມ້ → ປິດໄມ້ເກົ່າ ເຫຼືອໄມ້ໃໝ່ສຸດ
   if (n >= 2)
   {
      ulong    newest = 0;
      datetime tNew   = 0;
      for (int i = 0; i < n; i++)
      {
         if (!PositionSelectByTicket(pos[i])) continue;
         const datetime t = (datetime)PositionGetInteger(POSITION_TIME);
         if (newest == 0 || t > tNew || (t == tNew && pos[i] > newest)) { newest = pos[i]; tNew = t; }
      }
      for (int i = 0; i < n; i++)
         if (pos[i] != newest) trade.PositionClose(pos[i]);
      SetChain(newest);
      return;
   }

   // ບໍ່ມີໄມ້ → ລຶບ pending ແລ້ວລໍຖ້າເຈົ້າກົດ BUY/SELL
   if (n == 0)
   {
      if (g_chain != 0) { SetChain(0); g_waitSince = TimeCurrent(); }
      DeleteMyPendings();
      const ulong click = FindManualClick();
      if (click == 0) return;
      if (!PositionSelectByTicket(click)) return;
      SetChain(click);
      RememberAdopted((ulong)PositionGetInteger(POSITION_IDENTIFIER));
      Print("Adopted your ", (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY" : "SELL"),
            " ", DoubleToString(PositionGetDouble(POSITION_VOLUME), 2), " ticket ", click);
      n = MyPositions(pos);
      if (n == 0) return;
   }

   // ມີໄມ້ດຽວ → ຮັກສາ stop ກົງກັນຂ້າມ
   if (!PositionSelectByTicket(pos[0])) return;
   const TR_SIDE side = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? TR_BUY : TR_SELL;
   const double  lot  = PositionGetDouble(POSITION_VOLUME);
   const ENUM_ORDER_TYPE want = (side == TR_BUY) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;

   const ulong pend = FindReversePending(want);
   if (pend == 0) PlaceReverse(side, NormLot(lot + IncreaseLot));
   else           TrailReverse(pend, side);
}

void ShowStatus()
{
   ulong pos[];
   const int n = MyPositions(pos);
   string s = "ManualTrailReverse  magic " + (string)MagicNumber + "\n";
   s += "Daily P/L: " + DoubleToString(DailyPL(), 2) + " USD  (TP " + DoubleToString(DailyProfitTargetUSD, 0)
      + " / SL -" + DoubleToString(DailyLossLimitUSD, 0) + ")\n";
   if (g_stopDay != 0) s += "STOPPED until next day\n";
   else if (n > 0 && PositionSelectByTicket(pos[0]))
      s += "Pos: " + ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "BUY " : "SELL ")
         + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2) + "  reverse @ " + (string)ReverseDist() + " pts\n";
   else s += "Waiting for your BUY/SELL click\n";
   Comment(s);
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_gvStopDay = "ManualTrailReverse_StopDay_" + _Symbol + "_" + (string)MagicNumber;
   g_gvChain   = "ManualTrailReverse_Chain_"   + _Symbol + "_" + (string)MagicNumber;
   g_waitSince = TimeCurrent();   // ໄມ້ທີ່ມີກ່ອນເປີດ EA ບໍ່ຮັບ — ກົດໃໝ່ຫຼັງເປີດ EA

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   if (AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("ຄຳເຕືອນ: ບັນຊີບໍ່ແມ່ນ Hedging — ຂະນະ reverse ຈະມີ 2 ໄມ້ຊົ່ວຄາວ ຕ້ອງໃຊ້ Hedging");

   if (GlobalVariableCheck(g_gvStopDay))
   {
      g_stopDay = (datetime)GlobalVariableGet(g_gvStopDay);
      if (g_stopDay != DayStart()) { g_stopDay = 0; GlobalVariableDel(g_gvStopDay); }
   }
   // chain ທີ່ຄ້າງກ່ອນ restart → ຮັບຕໍ່
   if (GlobalVariableCheck(g_gvChain))
   {
      const ulong tk = (ulong)GlobalVariableGet(g_gvChain);
      if (tk != 0 && PositionSelectByTicket(tk) && PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         g_chain = tk;
         RememberAdopted((ulong)PositionGetInteger(POSITION_IDENTIFIER));
      }
      else GlobalVariableDel(g_gvChain);
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { Comment(""); }

void OnTick()
{
   Process();
   ShowStatus();
}

// ຕອບໂຕ້ທັນທີເມື່ອ stop ຕິດ ຫຼື ເຈົ້າກົດ — ບໍ່ລໍ tick ຖັດໄປ
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if (trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if (trans.symbol != _Symbol) return;
   Process();
}
//+------------------------------------------------------------------+
