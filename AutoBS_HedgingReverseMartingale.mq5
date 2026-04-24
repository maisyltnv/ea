//+------------------------------------------------------------------+
//|                              AutoBS_HedgingReverseMartingale.mq5 |
//|                                                                   |
//| ສະຫຼຸບ (ລາວ):                                                     |
//| - ໃຊ້ໄດ້ເທົ່າໃນ chart M1; ຮອງຮັບບັນຊີ hedging.                      |
//| - ຝັ່ງຊື້ ແລະ ຝັ່ງຂາຍ ເຮັດວຽກແຍກກັນ (Magic ຄົນລະຊຸດ).               |
//| - ເມື່ອເລີ່ມ: ເປີດ market ຊື້+ວາງ Buy Stop ແລະ market ຂາຍ+Sell Stop ພ້ອມກັນ. |
//| - ຊື້: SL/TP ຕາມ points; Buy Stop ຢູ່ເທິງລາຄາເຂົ້າຕົວທຳອິດ; TP ຂອງ Stop |
//|   ຕ້ອງເທົ່າກັບ TP ຕົວຊື້ທຳອິດທຸກຈຸດ.                               |
//| - ຖ້າ order ຊື້ຝັ່ງໃດຖືກ SL: ປິດ market ຊື້ທັງໝົດ, ລຶບ Buy Stop, ເລີ່ມວົງຈອນຊື້ໃໝ່. |
//| - ຖ້າ Buy Stop ເຕັມເປັນຕຳແໜ່ງ: ຍ້າຍ SL ຕົວຊື້ທຳອິດໄປເທົ່າກັບ SL ຂອງຕົວທີສອງ, |
//|   ບໍ່ປ່ຽນ TP ຕົວທຳອິດ.                                           |
//| - ຖ້າຝັ່ງຊື້ໃດຕົວຖືກ TP: ປິດຊື້ທີ່ເຫຼືອ, ລຶບ Buy Stop, ເລີ່ມວົງຈອນຊື້ໃໝ່.   |
//| - ຂາຍ: ກົງກັນຂ້າງລຸ່ມ (Sell Stop, SL/TP ກົງກັນກັບກົດຊື້).            |
//| - ຈັດການເທົ່າອໍເດີທີ່ມີ Magic ຂອງ EA; ກວດ stops ຂັ້ນຕ່ຳຂອງໂບຣກເກີ.      |
//|                                                                   |
//| Summary (EN): Independent buy/sell cycles on M1; hedging. Each     |
//| cycle: market + stop pending; pending TP equals first-leg TP;    |
//| on stop fill, first SL syncs to second leg SL; any SL/TP on that |
//| side closes all that side and restarts that side only.           |
//+------------------------------------------------------------------+
#property copyright "AutoBS"
#property version   "1.01"
#property strict
#property description "M1 hedging EA: dual independent buy/sell cycles (market+stop); shared TP on pending; SL sync on stop fill; SL/TP restarts per side."

#include <Trade/Trade.mqh>

//--- inputs
input double LotSize               = 0.01;
input int    StopLossPoints        = 100;
input int    TakeProfitPoints      = 200;
input int    PendingDistancePoints = 100;
input long   MagicNumber           = 505050; // Buy cycle; Sell = MagicNumber + 1000000
input int    SlippagePoints        = 20;

//--- derived magic (documented in OnInit Print)
long g_magicBuy  = 0;
long g_magicSell = 0;

CTrade g_tradeBuy;
CTrade g_tradeSell;

//--- per-side state (independent)
struct SideBook {
  ulong  firstTicket;   // first market order of current cycle
  ulong  pendingTicket; // BuyStop / SellStop ticket (0 if none)
  double firstTpPrice;  // locked TP for cycle (pending uses same)
  bool   slSynced;      // buy: synced first SL to second; sell: mirrored
  bool   bulkClose;     // ignore our own OUT deals while true
};

SideBook g_buy;
SideBook g_sell;

//+------------------------------------------------------------------+
//| Ticket of position opened by last market deal (ResultPosition()  |
//| is not available in all CTrade builds).                          |
//+------------------------------------------------------------------+
ulong FindLatestPositionTicket(const long magic, const ENUM_POSITION_TYPE typ) {
  ulong best = 0;
  datetime bestT = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != magic)
      continue;
    if ((int)PositionGetInteger(POSITION_TYPE) != typ)
      continue;
    const datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
    if (tm >= bestT) {
      bestT = tm;
      best = t;
    }
  }
  return best;
}

ulong PositionTicketFromLastTrade(CTrade &tr, const long magic,
                                  const ENUM_POSITION_TYPE typ) {
  const ulong deal = tr.ResultDeal();
  if (deal > 0 && HistoryDealSelect(deal)) {
    const long pid = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
    if (pid > 0) {
      const ulong pt = (ulong)pid;
      if (PositionSelectByTicket(pt) && PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (long)PositionGetInteger(POSITION_MAGIC) == magic)
        return pt;
    }
  }
  return FindLatestPositionTicket(magic, typ);
}

//+------------------------------------------------------------------+
int DigitsCount() {
  return (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
}

double PointValue() {
  return SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

double NormPrice(const double p) {
  return NormalizeDouble(p, DigitsCount());
}

int StopsLevelPoints() {
  return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
}

//+------------------------------------------------------------------+
//| Min distance in price from 'entry' to SL/TP for a BUY          |
//+------------------------------------------------------------------+
bool CheckBuyStopsValid(const double entry, const double sl, const double tp, string &why) {
  const double pt = PointValue();
  if (pt <= 0.0) {
    why = "point=0";
    return false;
  }
  const int lvl = StopsLevelPoints();
  const double minDist = lvl * pt;
  if (sl > 0.0 && (entry - sl) < minDist - 1e-10) {
    why = StringFormat("Buy SL dist %.5f < min %.5f (lvl=%d)", entry - sl, minDist, lvl);
    return false;
  }
  if (tp > 0.0 && (tp - entry) < minDist - 1e-10) {
    why = StringFormat("Buy TP dist %.5f < min %.5f (lvl=%d)", tp - entry, minDist, lvl);
    return false;
  }
  return true;
}

//+------------------------------------------------------------------+
//| Min distance for SELL                                            |
//+------------------------------------------------------------------+
bool CheckSellStopsValid(const double entry, const double sl, const double tp, string &why) {
  const double pt = PointValue();
  if (pt <= 0.0) {
    why = "point=0";
    return false;
  }
  const int lvl = StopsLevelPoints();
  const double minDist = lvl * pt;
  if (sl > 0.0 && (sl - entry) < minDist - 1e-10) {
    why = StringFormat("Sell SL dist %.5f < min %.5f (lvl=%d)", sl - entry, minDist, lvl);
    return false;
  }
  if (tp > 0.0 && (entry - tp) < minDist - 1e-10) {
    why = StringFormat("Sell TP dist %.5f < min %.5f (lvl=%d)", entry - tp, minDist, lvl);
    return false;
  }
  return true;
}

//+------------------------------------------------------------------+
bool CheckBuyStopPendingValid(const double pendPrice, const double sl, const double tp,
                              string &why) {
  const double pt = PointValue();
  const int lvl = StopsLevelPoints();
  const double minDist = lvl * pt;
  if (sl > 0.0 && (pendPrice - sl) < minDist - 1e-10) {
    why = StringFormat("BuyStop SL dist < min (lvl=%d)", lvl);
    return false;
  }
  if (tp > 0.0 && (tp - pendPrice) < minDist - 1e-10) {
    why = StringFormat("BuyStop TP dist < min (lvl=%d)", lvl);
    return false;
  }
  return true;
}

bool CheckSellStopPendingValid(const double pendPrice, const double sl, const double tp,
                               string &why) {
  const double pt = PointValue();
  const int lvl = StopsLevelPoints();
  const double minDist = lvl * pt;
  if (sl > 0.0 && (sl - pendPrice) < minDist - 1e-10) {
    why = StringFormat("SellStop SL dist < min (lvl=%d)", lvl);
    return false;
  }
  if (tp > 0.0 && (pendPrice - tp) < minDist - 1e-10) {
    why = StringFormat("SellStop TP dist < min (lvl=%d)", lvl);
    return false;
  }
  return true;
}

//+------------------------------------------------------------------+
double NormalizeLots(const double lots) {
  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
  double v = lots;
  if (step > 0.0)
    v = MathRound(v / step) * step;
  if (v < minv)
    v = minv;
  if (maxv > 0.0 && v > maxv)
    v = maxv;
  return v;
}

//+------------------------------------------------------------------+
int CountBuyMarkets(const long magic) {
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != magic)
      continue;
    if ((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
      continue;
    n++;
  }
  return n;
}

int CountSellMarkets(const long magic) {
  int n = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != magic)
      continue;
    if ((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
      continue;
    n++;
  }
  return n;
}

int CountBuyStops(const long magic) {
  int n = 0;
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    const ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != magic)
      continue;
    if ((int)OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_STOP)
      n++;
  }
  return n;
}

int CountSellStops(const long magic) {
  int n = 0;
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    const ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != magic)
      continue;
    if ((int)OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_SELL_STOP)
      n++;
  }
  return n;
}

//+------------------------------------------------------------------+
void DeleteBuyStops(const long magic) {
  g_tradeBuy.SetExpertMagicNumber(magic);
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    const ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != magic)
      continue;
    if ((int)OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_BUY_STOP)
      continue;
    g_tradeBuy.OrderDelete(ot);
  }
}

void DeleteSellStops(const long magic) {
  g_tradeSell.SetExpertMagicNumber(magic);
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    const ulong ot = OrderGetTicket(i);
    if (ot == 0 || !OrderSelect(ot))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != _Symbol)
      continue;
    if ((long)OrderGetInteger(ORDER_MAGIC) != magic)
      continue;
    if ((int)OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_SELL_STOP)
      continue;
    g_tradeSell.OrderDelete(ot);
  }
}

//+------------------------------------------------------------------+
void CloseAllBuyMarkets(const long magic) {
  g_buy.bulkClose = true;
  g_tradeBuy.SetExpertMagicNumber(magic);
  g_tradeBuy.SetDeviationInPoints(SlippagePoints);
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != magic)
      continue;
    if ((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
      continue;
    g_tradeBuy.PositionClose(t);
  }
  g_buy.bulkClose = false;
}

void CloseAllSellMarkets(const long magic) {
  g_sell.bulkClose = true;
  g_tradeSell.SetExpertMagicNumber(magic);
  g_tradeSell.SetDeviationInPoints(SlippagePoints);
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != magic)
      continue;
    if ((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
      continue;
    g_tradeSell.PositionClose(t);
  }
  g_sell.bulkClose = false;
}

//+------------------------------------------------------------------+
void ResetBuyBook() {
  g_buy.firstTicket = 0;
  g_buy.pendingTicket = 0;
  g_buy.firstTpPrice = 0.0;
  g_buy.slSynced = false;
}

void ResetSellBook() {
  g_sell.firstTicket = 0;
  g_sell.pendingTicket = 0;
  g_sell.firstTpPrice = 0.0;
  g_sell.slSynced = false;
}

//+------------------------------------------------------------------+
bool StartBuyCycle() {
  const int m = CountBuyMarkets(g_magicBuy);
  const int p = CountBuyStops(g_magicBuy);
  if (m > 0 || p > 0) {
    Print("[Buy] StartBuyCycle skipped: already have m=", m, " p=", p);
    return false;
  }

  ResetBuyBook();

  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT))
    SymbolSelect(_Symbol, true);

  MqlTick tk;
  if (!SymbolInfoTick(_Symbol, tk))
    return false;

  const double pt = PointValue();
  if (pt <= 0.0)
    return false;

  const double ask = tk.ask;
  const double sl = NormPrice(ask - (double)StopLossPoints * pt);
  const double tp = NormPrice(ask + (double)TakeProfitPoints * pt);

  string why = "";
  if (!CheckBuyStopsValid(ask, sl, tp, why)) {
    Print("[Buy] Invalid first SL/TP: ", why);
    return false;
  }

  const double lots = NormalizeLots(LotSize);
  g_tradeBuy.SetExpertMagicNumber(g_magicBuy);
  g_tradeBuy.SetDeviationInPoints(SlippagePoints);

  if (!g_tradeBuy.Buy(lots, _Symbol, 0.0, sl, tp, "ABS_B_first")) {
    Print("[Buy] Buy failed err=", GetLastError());
    return false;
  }

  const ulong posTk =
      PositionTicketFromLastTrade(g_tradeBuy, g_magicBuy, POSITION_TYPE_BUY);
  if (posTk == 0 || !PositionSelectByTicket(posTk)) {
    Print("[Buy] No position ticket after Buy");
    return false;
  }

  g_buy.firstTicket = posTk;
  g_buy.firstTpPrice = tp;

  const double openFirst = PositionGetDouble(POSITION_PRICE_OPEN);
  const double stopPrice =
      NormPrice(openFirst + (double)PendingDistancePoints * pt);
  const double slStop = NormPrice(stopPrice - (double)StopLossPoints * pt);
  const double tpStop = NormPrice(g_buy.firstTpPrice); // exact same TP as first

  if (!CheckBuyStopPendingValid(stopPrice, slStop, tpStop, why)) {
    Print("[Buy] Invalid BuyStop levels: ", why);
    // keep market; try to continue without pending? spec requires pending — abort cycle repair in OnTick
    return false;
  }

  if (!g_tradeBuy.BuyStop(lots, stopPrice, _Symbol, slStop, tpStop, ORDER_TIME_GTC, 0,
                          "ABS_B_stop")) {
    Print("[Buy] BuyStop failed err=", GetLastError());
    return false;
  }

  g_buy.pendingTicket = g_tradeBuy.ResultOrder();
  Print("[Buy] Cycle started first=", g_buy.firstTicket, " pend=", g_buy.pendingTicket,
        " TP=", DoubleToString(tpStop, DigitsCount()));
  return true;
}

//+------------------------------------------------------------------+
bool StartSellCycle() {
  const int m = CountSellMarkets(g_magicSell);
  const int p = CountSellStops(g_magicSell);
  if (m > 0 || p > 0) {
    Print("[Sell] StartSellCycle skipped: m=", m, " p=", p);
    return false;
  }

  ResetSellBook();

  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT))
    SymbolSelect(_Symbol, true);

  MqlTick tk;
  if (!SymbolInfoTick(_Symbol, tk))
    return false;

  const double pt = PointValue();
  if (pt <= 0.0)
    return false;

  const double bid = tk.bid;
  const double sl = NormPrice(bid + (double)StopLossPoints * pt);
  const double tp = NormPrice(bid - (double)TakeProfitPoints * pt);

  string why = "";
  if (!CheckSellStopsValid(bid, sl, tp, why)) {
    Print("[Sell] Invalid first SL/TP: ", why);
    return false;
  }

  const double lots = NormalizeLots(LotSize);
  g_tradeSell.SetExpertMagicNumber(g_magicSell);
  g_tradeSell.SetDeviationInPoints(SlippagePoints);

  if (!g_tradeSell.Sell(lots, _Symbol, 0.0, sl, tp, "ABS_S_first")) {
    Print("[Sell] Sell failed err=", GetLastError());
    return false;
  }

  const ulong posTk =
      PositionTicketFromLastTrade(g_tradeSell, g_magicSell, POSITION_TYPE_SELL);
  if (posTk == 0 || !PositionSelectByTicket(posTk)) {
    Print("[Sell] No position ticket after Sell");
    return false;
  }

  g_sell.firstTicket = posTk;
  g_sell.firstTpPrice = tp;

  const double openFirst = PositionGetDouble(POSITION_PRICE_OPEN);
  const double stopPrice =
      NormPrice(openFirst - (double)PendingDistancePoints * pt);
  const double slStop = NormPrice(stopPrice + (double)StopLossPoints * pt);
  const double tpStop = NormPrice(g_sell.firstTpPrice);

  if (!CheckSellStopPendingValid(stopPrice, slStop, tpStop, why)) {
    Print("[Sell] Invalid SellStop levels: ", why);
    return false;
  }

  if (!g_tradeSell.SellStop(lots, stopPrice, _Symbol, slStop, tpStop, ORDER_TIME_GTC, 0,
                            "ABS_S_stop")) {
    Print("[Sell] SellStop failed err=", GetLastError());
    return false;
  }

  g_sell.pendingTicket = g_tradeSell.ResultOrder();
  Print("[Sell] Cycle started first=", g_sell.firstTicket, " pend=", g_sell.pendingTicket,
        " TP=", DoubleToString(tpStop, DigitsCount()));
  return true;
}

//+------------------------------------------------------------------+
void HandleBuySlRestart() {
  Print("[Buy] SL hit -> close all, delete stops, new cycle");
  DeleteBuyStops(g_magicBuy);
  CloseAllBuyMarkets(g_magicBuy);
  ResetBuyBook();
  StartBuyCycle();
}

void HandleBuyTpRestart() {
  Print("[Buy] TP hit -> close all, delete stops, new cycle");
  DeleteBuyStops(g_magicBuy);
  CloseAllBuyMarkets(g_magicBuy);
  ResetBuyBook();
  StartBuyCycle();
}

void HandleSellSlRestart() {
  Print("[Sell] SL hit -> close all, delete stops, new cycle");
  DeleteSellStops(g_magicSell);
  CloseAllSellMarkets(g_magicSell);
  ResetSellBook();
  StartSellCycle();
}

void HandleSellTpRestart() {
  Print("[Sell] TP hit -> close all, delete stops, new cycle");
  DeleteSellStops(g_magicSell);
  CloseAllSellMarkets(g_magicSell);
  ResetSellBook();
  StartSellCycle();
}

//+------------------------------------------------------------------+
void SyncBuyFirstSlFromSecond() {
  if (g_buy.firstTicket == 0 || g_buy.slSynced)
    return;
  if (CountBuyMarkets(g_magicBuy) != 2)
    return;

  ulong secondTk = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != g_magicBuy)
      continue;
    if ((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
      continue;
    if (t != g_buy.firstTicket)
      secondTk = t;
  }
  if (secondTk == 0 || !PositionSelectByTicket(secondTk))
    return;
  const double newSl = PositionGetDouble(POSITION_SL);

  if (!PositionSelectByTicket(g_buy.firstTicket))
    return;
  const double firstTp = PositionGetDouble(POSITION_TP); // keep first TP unchanged

  g_tradeBuy.SetExpertMagicNumber(g_magicBuy);
  g_tradeBuy.SetDeviationInPoints(SlippagePoints);
  if (g_tradeBuy.PositionModify(g_buy.firstTicket, newSl, firstTp))
    g_buy.slSynced = true;
  else
    Print("[Buy] PositionModify first SL failed err=", GetLastError());
}

//+------------------------------------------------------------------+
void SyncSellFirstSlFromSecond() {
  if (g_sell.firstTicket == 0 || g_sell.slSynced)
    return;
  if (CountSellMarkets(g_magicSell) != 2)
    return;

  ulong secondTk = 0;
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    const ulong t = PositionGetTicket(i);
    if (t == 0 || !PositionSelectByTicket(t))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != _Symbol)
      continue;
    if ((long)PositionGetInteger(POSITION_MAGIC) != g_magicSell)
      continue;
    if ((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
      continue;
    if (t != g_sell.firstTicket)
      secondTk = t;
  }
  if (secondTk == 0 || !PositionSelectByTicket(secondTk))
    return;
  const double newSl = PositionGetDouble(POSITION_SL);

  if (!PositionSelectByTicket(g_sell.firstTicket))
    return;
  const double firstTp = PositionGetDouble(POSITION_TP);

  g_tradeSell.SetExpertMagicNumber(g_magicSell);
  g_tradeSell.SetDeviationInPoints(SlippagePoints);
  if (g_tradeSell.PositionModify(g_sell.firstTicket, newSl, firstTp))
    g_sell.slSynced = true;
  else
    Print("[Sell] PositionModify first SL failed err=", GetLastError());
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
  if (trans.type != TRADE_TRANSACTION_DEAL_ADD)
    return;
  if (trans.deal == 0)
    return;
  if (!HistoryDealSelect(trans.deal))
    return;

  const string dsym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
  if (dsym != _Symbol)
    return;

  const long magic = (long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
  const long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
  const long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);

  if (magic == g_magicBuy) {
    if (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) {
      if (g_buy.bulkClose && reason == DEAL_REASON_CLIENT)
        return;
      if (reason == DEAL_REASON_SL)
        HandleBuySlRestart();
      else if (reason == DEAL_REASON_TP)
        HandleBuyTpRestart();
    }
  } else if (magic == g_magicSell) {
    if (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) {
      if (g_sell.bulkClose && reason == DEAL_REASON_CLIENT)
        return;
      if (reason == DEAL_REASON_SL)
        HandleSellSlRestart();
      else if (reason == DEAL_REASON_TP)
        HandleSellTpRestart();
    }
  }
}

//+------------------------------------------------------------------+
void RepairBuySideIfNeeded() {
  const int m = CountBuyMarkets(g_magicBuy);
  const int p = CountBuyStops(g_magicBuy);

  if (m == 0 && p == 0) {
    ResetBuyBook();
    StartBuyCycle();
    return;
  }

  if (m == 1 && p == 0 && g_buy.firstTicket != 0) {
    // pending missing: re-place from first position
    if (!PositionSelectByTicket(g_buy.firstTicket))
      return;
    const double pt = PointValue();
    const double openFirst = PositionGetDouble(POSITION_PRICE_OPEN);
    const double tpFirst = NormPrice(g_buy.firstTpPrice);
    const double stopPrice =
        NormPrice(openFirst + (double)PendingDistancePoints * pt);
    const double slStop = NormPrice(stopPrice - (double)StopLossPoints * pt);
    const double tpStop = NormPrice(tpFirst);

    string why = "";
    if (!CheckBuyStopPendingValid(stopPrice, slStop, tpStop, why)) {
      Print("[Buy] Repair BuyStop invalid: ", why);
      return;
    }
    const double lots = NormalizeLots(LotSize);
    g_tradeBuy.SetExpertMagicNumber(g_magicBuy);
    g_tradeBuy.SetDeviationInPoints(SlippagePoints);
    if (g_tradeBuy.BuyStop(lots, stopPrice, _Symbol, slStop, tpStop, ORDER_TIME_GTC, 0,
                           "ABS_B_stop")) {
      g_buy.pendingTicket = g_tradeBuy.ResultOrder();
      Print("[Buy] Repaired BuyStop ticket=", g_buy.pendingTicket);
    }
  }
}

void RepairSellSideIfNeeded() {
  const int m = CountSellMarkets(g_magicSell);
  const int p = CountSellStops(g_magicSell);

  if (m == 0 && p == 0) {
    ResetSellBook();
    StartSellCycle();
    return;
  }

  if (m == 1 && p == 0 && g_sell.firstTicket != 0) {
    if (!PositionSelectByTicket(g_sell.firstTicket))
      return;
    const double pt = PointValue();
    const double openFirst = PositionGetDouble(POSITION_PRICE_OPEN);
    const double tpFirst = NormPrice(g_sell.firstTpPrice);
    const double stopPrice =
        NormPrice(openFirst - (double)PendingDistancePoints * pt);
    const double slStop = NormPrice(stopPrice + (double)StopLossPoints * pt);
    const double tpStop = NormPrice(tpFirst);

    string why = "";
    if (!CheckSellStopPendingValid(stopPrice, slStop, tpStop, why)) {
      Print("[Sell] Repair SellStop invalid: ", why);
      return;
    }
    const double lots = NormalizeLots(LotSize);
    g_tradeSell.SetExpertMagicNumber(g_magicSell);
    g_tradeSell.SetDeviationInPoints(SlippagePoints);
    if (g_tradeSell.SellStop(lots, stopPrice, _Symbol, slStop, tpStop, ORDER_TIME_GTC, 0,
                            "ABS_S_stop")) {
      g_sell.pendingTicket = g_tradeSell.ResultOrder();
      Print("[Sell] Repaired SellStop ticket=", g_sell.pendingTicket);
    }
  }
}

//+------------------------------------------------------------------+
int OnInit() {
  if (Period() != PERIOD_M1) {
    Print("AutoBS_HedgingReverseMartingale: attach this EA to an M1 chart. Period=",
          EnumToString((ENUM_TIMEFRAMES)Period()));
    return INIT_FAILED;
  }

  g_magicBuy = MagicNumber;
  g_magicSell = MagicNumber + 1000000;

  g_tradeBuy.SetExpertMagicNumber(g_magicBuy);
  g_tradeSell.SetExpertMagicNumber(g_magicSell);
  g_tradeBuy.SetDeviationInPoints(SlippagePoints);
  g_tradeSell.SetDeviationInPoints(SlippagePoints);

  ResetBuyBook();
  ResetSellBook();

  Print("AutoBS_HedgingReverseMartingale init: symbol=", _Symbol, " M1 OK. MagicBuy=",
        g_magicBuy, " MagicSell=", g_magicSell, " SL=", StopLossPoints, " TP=",
        TakeProfitPoints, " PendDist=", PendingDistancePoints);

  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT))
    SymbolSelect(_Symbol, true);

  // Immediate: both sides
  if (!StartBuyCycle())
    Print("OnInit: Buy cycle start failed");
  if (!StartSellCycle())
    Print("OnInit: Sell cycle start failed");

  return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  Print("AutoBS_HedgingReverseMartingale stop reason=", reason);
}

//+------------------------------------------------------------------+
void OnTick() {
  if (!SymbolInfoInteger(_Symbol, SYMBOL_SELECT))
    SymbolSelect(_Symbol, true);

  // SL sync when BuyStop / SellStop became second market position
  if (CountBuyMarkets(g_magicBuy) != 2)
    g_buy.slSynced = false;
  else
    SyncBuyFirstSlFromSecond();

  if (CountSellMarkets(g_magicSell) != 2)
    g_sell.slSynced = false;
  else
    SyncSellFirstSlFromSecond();

  // light repair (no duplicate full cycles if positions exist)
  static datetime lastRepair = 0;
  if (TimeCurrent() - lastRepair >= 1) {
    lastRepair = TimeCurrent();
    RepairBuySideIfNeeded();
    RepairSellSideIfNeeded();
  }
}

//+------------------------------------------------------------------+
