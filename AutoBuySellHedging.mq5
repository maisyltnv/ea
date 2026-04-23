//+------------------------------------------------------------------+
//| AutoBuySellHedging.mq5 (Hedging ladder + auto/manual start)      |
//|                                                                  |
//| ຈຸດປະສົງ: ສ້າງຂັ້ນ hedge ດ້ວຍ pending stop ສະຫຼັບຝັ່ງ; ມີ TP ຕໍ່ຂັ້ນ.   |
//| ເມື່ອມີ position ໃດໜຶ່ງໂດນ TP -> ປິດທຸກອໍເດີ/position ຂອງ symbol ນີ້.   |
//|                                                                  |
//| ວິທີເລີ່ມຮອບ (3 ຊ່ອງທາງ):                                         |
//|  1) ປຸ່ມ chart BUY/SELL (ເປີດ market magic=0 = "manual" ສຳລັບ EA)   |
//|  2) ຜູ້ໃຊ້ເປີດມືຝັ່ງດຽວ (magic != MagicNumber) -> StartBuy/SellCycle |
//|  3) Auto: ບໍ່ມີ manual ສອງຝັ່ງ -> EA ເປີດ Buy ຫຼື Sell lot=Step1     |
//|     ຕາມ g_nextMode; ຫຼັງ TP ສັບຝັ່ງຕາມ deal ປິດ (AnyTPHit).         |
//|                                                                  |
//| ລຳດັບ lot ຂັ້ນ (ປັບໄດ້ Lots_Step1..5): ຄ່າເລີ່ມຕົ້ນ 0.01,0.03,...   |
//| BUY-start: BUY Step1 -> SELL STOP Step2 -> BUY STOP Step3 ->      |
//|            SELL STOP Step4 -> BUY STOP Step5 -> ລໍ TP             |
//| SELL-start: ກົງກັນຂ້າມ (mirror).                                   |
//|                                                                  |
//| ເງື່ອນໄຂ M1 EMA (ເປີດ/ປິດ UseEmaM1Filter, EmaM1Shift=ແທ່ງທີ່ກວດ):   |
//|  ຕ້ອງຜ່ານກ່ອນ: ປຸ່ມ market, auto start, StartBuy/SellCycle,        |
//|  ແລະ ກ່ອນວາງ pending ຂັ້ນຕໍ່ໄປໃນຮອບກຳລັງເຮັດວຽກ.                  |
//|  ຜ່ານເມື່ອ (ໃນ PERIOD_M1, bar shift = EmaM1Shift, ຄ່າເລີ່ມ 1):      |
//|   Bull: EMA14 > EMA26 > EMA50 > EMA100 > EMA200                   |
//|   ຫຼື Bear: EMA14 < EMA26 < EMA50 < EMA100 < EMA200                 |
//|  ຖ້າບໍ່ຕົງທັງຄູ່ -> ບໍ່ສົ່ງອໍເດີໃໝ່ (ລໍຈົນກວ່າຈະຕົງ).              |
//|                                                                  |
//| ຣີເຊັດ: ປິດຫມົດມືບໍ່ມີ position/order -> MODE_NONE ພ້ອມເລີ່ມໃໝ່.   |
//+------------------------------------------------------------------+

#property strict
#property description "HedgingManual EA: user opens first BUY/SELL"
#property description "EA builds hedge ladder of pending stops"
#property description "Closes all positions on any TP hit."
#property version "1.00"

#include <Trade/Trade.mqh>

//--- inputs (5 steps: 0.01, 0.03, 0.06, 0.17, 0.4)
input double Lots_Step1 = 0.01; // Step 1 hedge lot
input double Lots_Step2 = 0.03; // Step 2 hedge lot
input double Lots_Step3 = 0.06; // Step 3 hedge lot
input double Lots_Step4 = 0.17; // Step 4 hedge lot
input double Lots_Step5 = 0.40; // Step 5 hedge lot (final)
input int DistancePoints = 100; // Distance between hedge orders (points)
input int TPPoints = 200;      // Take profit distance (points) from each entry
input int SlippagePoints = 20;  // Slippage (points)
input int MagicNumber = 987654; // Magic for EA-created orders
input double StartLot = 0.01;   // Lot when starting via BUY/SELL button

//--- M1 EMA stack filter (must pass before any new order)
input bool   UseEmaM1Filter = true; // false = disable EMA gate
input int    EmaM1Shift   = 1;      // bar shift (1 = last closed M1 bar)

//--- chart button names (for start BUY / start SELL)
#define BTN_BUY_NAME "HedgingManualBtnBUY"
#define BTN_SELL_NAME "HedgingManualBtnSELL"

//--- trade object
CTrade trade;

//+------------------------------------------------------------------+
//| Anchor SL/TP: make all BUYs share first BUY SL/TP; same for SELL |
//+------------------------------------------------------------------+
bool FindAnchorForSide(const ENUM_POSITION_TYPE side, double &slOut, double &tpOut) {
  slOut = 0.0;
  tpOut = 0.0;
  const string symbol = _Symbol;

  ulong bestTk = 0;
  long bestTime = LONG_MAX;

  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    // consider manual (magic 0) and EA (magic MagicNumber) positions only
    const int magic = (int)PositionGetInteger(POSITION_MAGIC);
    if (magic != 0 && magic != MagicNumber)
      continue;

    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != side)
      continue;

    const long t = (long)PositionGetInteger(POSITION_TIME_MSC);
    if (t < bestTime) {
      bestTime = t;
      bestTk = tk;
    }
  }

  if (bestTk == 0 || !PositionSelectByTicket(bestTk))
    return false;

  slOut = PositionGetDouble(POSITION_SL);
  tpOut = PositionGetDouble(POSITION_TP);
  return (slOut > 0.0 || tpOut > 0.0);
}

void EnforceAnchorsOnEAPositions() {
  const string symbol = _Symbol;
  const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  double buySL = 0.0, buyTP = 0.0, sellSL = 0.0, sellTP = 0.0;
  const bool hasBuyAnchor = FindAnchorForSide(POSITION_TYPE_BUY, buySL, buyTP);
  const bool hasSellAnchor = FindAnchorForSide(POSITION_TYPE_SELL, sellSL, sellTP);

  if (!hasBuyAnchor && !hasSellAnchor)
    return;

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  for (int i = PositionsTotal() - 1; i >= 0; --i) {
    const ulong tk = PositionGetTicket(i);
    if (tk == 0 || !PositionSelectByTicket(tk))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;
    if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      continue; // only modify EA-created positions

    const ENUM_POSITION_TYPE side = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
    double wantSL = 0.0, wantTP = 0.0;
    if (side == POSITION_TYPE_BUY && hasBuyAnchor) {
      wantSL = buySL; wantTP = buyTP;
    } else if (side == POSITION_TYPE_SELL && hasSellAnchor) {
      wantSL = sellSL; wantTP = sellTP;
    } else {
      continue;
    }

    const double curSL = PositionGetDouble(POSITION_SL);
    const double curTP = PositionGetDouble(POSITION_TP);

    const double nWantSL = (wantSL > 0.0) ? NormalizeDouble(wantSL, digits) : 0.0;
    const double nWantTP = (wantTP > 0.0) ? NormalizeDouble(wantTP, digits) : 0.0;
    const double nCurSL  = (curSL > 0.0)  ? NormalizeDouble(curSL, digits)  : 0.0;
    const double nCurTP  = (curTP > 0.0)  ? NormalizeDouble(curTP, digits)  : 0.0;

    if (nCurSL == nWantSL && nCurTP == nWantTP)
      continue;

    trade.PositionModify(tk, nWantSL, nWantTP);
  }
}

//--- mode and step state
enum StartMode {
  MODE_NONE = 0,      // no active cycle, waiting for manual start
  MODE_BUY_START = 1, // cycle started from manual BUY
  MODE_SELL_START = 2 // cycle started from manual SELL
};

enum HedgeStep {
  STEP_IDLE = 0,
  STEP_1 = 1, // after first hedge order placed (lot Step1)
  STEP_2 = 2,
  STEP_3 = 3,
  STEP_4 = 4,
  STEP_5 = 5 // final hedge order placed; then wait for TP
};

int      g_mode      = MODE_NONE;
int      g_step      = STEP_IDLE;
int      g_nextMode  = MODE_BUY_START; // which side to auto-start next cycle (BUY/SELL)
datetime g_lastTPDealTime = 0;         // last TP deal time we've processed

//--- Manual toggle pause/start behavior
bool     g_pauseAfterThisCycle = false; // set when user opens manual buy/sell while running
bool     g_pausedUntilManual   = false; // true = EA paused until next manual buy/sell
datetime g_lastExitDealTime    = 0;     // last SL/TP deal time processed (any magic, this symbol)

int g_ema14  = INVALID_HANDLE;
int g_ema26  = INVALID_HANDLE;
int g_ema50  = INVALID_HANDLE;
int g_ema100 = INVALID_HANDLE;
int g_ema200 = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Read one EMA buffer value (shift on M1)                          |
//+------------------------------------------------------------------+
bool ReadEma1(const int handle, const int shift, double &out) {
  if (handle == INVALID_HANDLE)
    return false;
  double b[1];
  if (CopyBuffer(handle, 0, shift, 1, b) != 1)
    return false;
  out = b[0];
  return true;
}

//+------------------------------------------------------------------+
//| M1: full bull stack OR full bear stack                         |
//+------------------------------------------------------------------+
bool TrendFilterEmaM1Ok() {
  if (!UseEmaM1Filter)
    return true;
  const int sh = EmaM1Shift;
  if (sh < 0)
    return false;

  double e14 = 0.0, e26 = 0.0, e50 = 0.0, e100 = 0.0, e200 = 0.0;
  if (!ReadEma1(g_ema14, sh, e14))
    return false;
  if (!ReadEma1(g_ema26, sh, e26))
    return false;
  if (!ReadEma1(g_ema50, sh, e50))
    return false;
  if (!ReadEma1(g_ema100, sh, e100))
    return false;
  if (!ReadEma1(g_ema200, sh, e200))
    return false;

  const bool bull =
      (e14 > e26) && (e26 > e50) && (e50 > e100) && (e100 > e200);
  const bool bear =
      (e14 < e26) && (e26 < e50) && (e50 < e100) && (e100 < e200);
  return bull || bear;
}

//+------------------------------------------------------------------+
//| Get hedge lot for step (1..5)                                    |
//+------------------------------------------------------------------+
double LotForStep(int step) {
  switch (step) {
  case 1:
    return Lots_Step1;
  case 2:
    return Lots_Step2;
  case 3:
    return Lots_Step3;
  case 4:
    return Lots_Step4;
  case 5:
    return Lots_Step5;
  default:
    return Lots_Step1;
  }
}

//+------------------------------------------------------------------+
//| Helper: close all positions and pending orders for this symbol   |
//+------------------------------------------------------------------+
void CloseAllAndReset() {
  string symbol = _Symbol;

  // Close positions (all magics, including manual)
  for (int i = PositionsTotal() - 1; i >= 0; i--) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    trade.PositionClose(ticket);
  }

  // Delete pending orders (all magics, including manual)
  for (int i = OrdersTotal() - 1; i >= 0; i--) {
    ulong ticket = OrderGetTicket(i);
    if (ticket == 0 || !OrderSelect(ticket))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != symbol)
      continue;

    trade.OrderDelete(ticket);
  }

  g_mode = MODE_NONE;
  g_step = STEP_IDLE;
}

//+------------------------------------------------------------------+
//| Helper: check if any TP has been hit (price reached TP)          |
//+------------------------------------------------------------------+
bool AnyTPHit() {
  // History-based TP detection (robust for backtest and live)
  datetime toTime = TimeCurrent();
  datetime fromTime = g_lastTPDealTime;

  if (!HistorySelect(fromTime, toTime))
    return false;

  string symbol = _Symbol;
  datetime newestTP = g_lastTPDealTime;
  ulong   lastTPDealTicket = 0;
  bool found = false;

  int deals = HistoryDealsTotal();
  for (int i = deals - 1; i >= 0; i--) {
    ulong dealTicket = HistoryDealGetTicket(i);
    if (dealTicket == 0)
      continue;

    if (HistoryDealGetString(dealTicket, DEAL_SYMBOL) != symbol)
      continue;

    ENUM_DEAL_ENTRY entry =
        (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    if (entry != DEAL_ENTRY_OUT) // closing deal only
      continue;

    ENUM_DEAL_REASON reason =
        (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
    if (reason != DEAL_REASON_TP)
      continue;

    datetime dTime =
        (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
    if (dTime <= g_lastTPDealTime)
      break; // older than or equal to last processed

    newestTP = dTime;
    lastTPDealTicket = dealTicket;
    found = true;
    break; // latest TP for this EA/symbol
  }

  if (!found)
    return false;

  // Remember time so we don't react twice
  g_lastTPDealTime = newestTP;

  // Decide next side based on which side actually took TP.
  // NOTE: In MT5, closing a BUY position creates a SELL deal,
  // and closing a SELL position creates a BUY deal.
  ENUM_DEAL_TYPE dealType =
      (ENUM_DEAL_TYPE)HistoryDealGetInteger(lastTPDealTicket, DEAL_TYPE);
  if (dealType == DEAL_TYPE_BUY)
    g_nextMode = MODE_SELL_START; // BUY deal closed a SELL position -> continue SELL
  else if (dealType == DEAL_TYPE_SELL)
    g_nextMode = MODE_BUY_START;  // SELL deal closed a BUY position -> continue BUY

  return true;
}

//+------------------------------------------------------------------+
//| Helper: check if any SL/TP has happened (this symbol)            |
//+------------------------------------------------------------------+
bool AnyExitHit(bool &isTP) {
  isTP = false;
  datetime toTime = TimeCurrent();
  datetime fromTime = g_lastExitDealTime;

  if (!HistorySelect(fromTime, toTime))
    return false;

  string symbol = _Symbol;
  datetime newest = g_lastExitDealTime;
  ulong lastDeal = 0;
  bool found = false;

  int deals = HistoryDealsTotal();
  for (int i = deals - 1; i >= 0; --i) {
    ulong dealTicket = HistoryDealGetTicket(i);
    if (dealTicket == 0)
      continue;
    if (HistoryDealGetString(dealTicket, DEAL_SYMBOL) != symbol)
      continue;

    ENUM_DEAL_ENTRY entry =
        (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
    if (entry != DEAL_ENTRY_OUT)
      continue;

    ENUM_DEAL_REASON reason =
        (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
    if (reason != DEAL_REASON_TP && reason != DEAL_REASON_SL)
      continue;

    datetime dTime =
        (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
    if (dTime <= g_lastExitDealTime)
      break;

    newest = dTime;
    lastDeal = dealTicket;
    found = true;
    isTP = (reason == DEAL_REASON_TP);
    break;
  }

  if (!found)
    return false;

  g_lastExitDealTime = newest;

  // Keep existing "next side" behavior only when TP happened
  if (isTP && lastDeal != 0) {
    ENUM_DEAL_TYPE dealType =
        (ENUM_DEAL_TYPE)HistoryDealGetInteger(lastDeal, DEAL_TYPE);
    if (dealType == DEAL_TYPE_BUY)
      g_nextMode = MODE_SELL_START;
    else if (dealType == DEAL_TYPE_SELL)
      g_nextMode = MODE_BUY_START;
  }
  return true;
}

//+------------------------------------------------------------------+
//| Helper: find first manual position (magic != MagicNumber)        |
//+------------------------------------------------------------------+
bool FindManualPosition(ENUM_POSITION_TYPE type, ulong &ticketOut) {
  string symbol = _Symbol;
  ticketOut = 0;

  int totalPos = PositionsTotal();
  for (int i = 0; i < totalPos; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    int magic = (int)PositionGetInteger(POSITION_MAGIC);
    if (magic == MagicNumber) // skip EA positions
      continue;

    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
      continue;

    ticketOut = ticket;
    return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Helper: get EA position (by type and lot), returns entry price   |
//+------------------------------------------------------------------+
bool GetEAPosition(ENUM_POSITION_TYPE type, double lot, double &priceOpen) {
  string symbol = _Symbol;
  int totalPos = PositionsTotal();

  for (int i = 0; i < totalPos; i++) {
    ulong ticket = PositionGetTicket(i);
    if (ticket == 0 || !PositionSelectByTicket(ticket))
      continue;
    if (PositionGetString(POSITION_SYMBOL) != symbol)
      continue;

    int magic = (int)PositionGetInteger(POSITION_MAGIC);
    if (magic != MagicNumber)
      continue;

    if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
      continue;

    double vol = PositionGetDouble(POSITION_VOLUME);
    if (MathAbs(vol - lot) > 1e-5)
      continue;

    priceOpen = PositionGetDouble(POSITION_PRICE_OPEN);
    return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Helper: check if EA pending order of type & lot exists           |
//+------------------------------------------------------------------+
bool HasEAPending(ENUM_ORDER_TYPE type, double lot) {
  string symbol = _Symbol;
  int totalOrd = OrdersTotal();

  for (int i = 0; i < totalOrd; i++) {
    ulong ticket = OrderGetTicket(i);
    if (ticket == 0 || !OrderSelect(ticket))
      continue;
    if (OrderGetString(ORDER_SYMBOL) != symbol)
      continue;

    int magic = (int)OrderGetInteger(ORDER_MAGIC);
    if (magic != MagicNumber)
      continue;

    if ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type)
      continue;

    double vol = OrderGetDouble(ORDER_VOLUME_INITIAL);
    if (MathAbs(vol - lot) > 1e-5)
      continue;

    return (true);
  }
  return (false);
}

//+------------------------------------------------------------------+
//| Start BUY-based hedge cycle from manual BUY position             |
//+------------------------------------------------------------------+
void StartBuyCycle(ulong manualTicket) {
  if (!PositionSelectByTicket(manualTicket))
    return;

  if (!TrendFilterEmaM1Ok()) {
    Print("[HedgingManual] BUY-start skipped: M1 EMA stack not aligned (need "
          "14>26>50>100>200 OR 14<26<50<100<200).");
    return;
  }

  string symbol = PositionGetString(POSITION_SYMBOL);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  double sl = PositionGetDouble(POSITION_SL);
  double tp = entry + TPPoints * point;
  tp = NormalizeDouble(tp, digits);

  // Set TP for manual BUY
  trade.PositionModify(manualTicket, sl, tp);

  // Place SELL STOP #1 (lot = 0.03 = Step2; order: 0.01 buy -> 0.03 sell ->
  // 0.06 buy -> 0.17 sell -> 0.40 buy)
  double sellPrice = entry - DistancePoints * point;
  sellPrice = NormalizeDouble(sellPrice, digits);
  // Use anchored SELL SL/TP if a SELL anchor already exists; otherwise fallback to old TP calc
  double aSL = 0.0, aTP = 0.0;
  bool hasAnchor = FindAnchorForSide(POSITION_TYPE_SELL, aSL, aTP);
  if (!hasAnchor) {
    aSL = 0.0;
    aTP = NormalizeDouble(sellPrice - TPPoints * point, digits);
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  if (trade.SellStop(Lots_Step2, sellPrice, symbol, aSL, aTP)) {
    Print("[HedgingManual] BUY-start: SELL STOP #1 (", Lots_Step2,
          ") placed at ", sellPrice, " TP=", aTP);
    g_mode = MODE_BUY_START;
    g_step = STEP_1;
  } else {
    Print("[HedgingManual] BUY-start: failed to place SELL STOP #1. Error=",
          GetLastError());
  }
}

//+------------------------------------------------------------------+
//| Start SELL-based hedge cycle from manual SELL position           |
//+------------------------------------------------------------------+
void StartSellCycle(ulong manualTicket) {
  if (!PositionSelectByTicket(manualTicket))
    return;

  if (!TrendFilterEmaM1Ok()) {
    Print("[HedgingManual] SELL-start skipped: M1 EMA stack not aligned (need "
          "14>26>50>100>200 OR 14<26<50<100<200).");
    return;
  }

  string symbol = PositionGetString(POSITION_SYMBOL);
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  double entry = PositionGetDouble(POSITION_PRICE_OPEN);
  double sl = PositionGetDouble(POSITION_SL);
  double tp = entry - TPPoints * point;
  tp = NormalizeDouble(tp, digits);

  // Set TP for manual SELL
  trade.PositionModify(manualTicket, sl, tp);

  // Place BUY STOP #1 (lot = 0.03 = Step2; order: 0.01 sell -> 0.03 buy -> 0.06
  // sell -> 0.17 buy -> 0.40 sell)
  double buyPrice = entry + DistancePoints * point;
  buyPrice = NormalizeDouble(buyPrice, digits);
  // Use anchored BUY SL/TP if a BUY anchor already exists; otherwise fallback to old TP calc
  double aSL = 0.0, aTP = 0.0;
  bool hasAnchor = FindAnchorForSide(POSITION_TYPE_BUY, aSL, aTP);
  if (!hasAnchor) {
    aSL = 0.0;
    aTP = NormalizeDouble(buyPrice + TPPoints * point, digits);
  }

  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);

  if (trade.BuyStop(Lots_Step2, buyPrice, symbol, aSL, aTP)) {
    Print("[HedgingManual] SELL-start: BUY STOP #1 (", Lots_Step2,
          ") placed at ", buyPrice, " TP=", aTP);
    g_mode = MODE_SELL_START;
    g_step = STEP_1;
  } else {
    Print("[HedgingManual] SELL-start: failed to place BUY STOP #1. Error=",
          GetLastError());
  }
}

//+------------------------------------------------------------------+
//| Create BUY / SELL start buttons on chart                         |
//+------------------------------------------------------------------+
void CreateStartButtons() {
  int x = 10;
  int y = 30;
  int w = 70;
  int h = 24;

  ObjectCreate(0, BTN_BUY_NAME, OBJ_BUTTON, 0, 0, 0);
  ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_XDISTANCE, x);
  ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_YDISTANCE, y);
  ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_XSIZE, w);
  ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_YSIZE, h);
  ObjectSetString(0, BTN_BUY_NAME, OBJPROP_TEXT, "BUY");
  ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_SELECTABLE, false);
  ObjectSetInteger(0, BTN_BUY_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);

  ObjectCreate(0, BTN_SELL_NAME, OBJ_BUTTON, 0, 0, 0);
  ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_XDISTANCE, x + w + 5);
  ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_YDISTANCE, y);
  ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_XSIZE, w);
  ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_YSIZE, h);
  ObjectSetString(0, BTN_SELL_NAME, OBJPROP_TEXT, "SELL");
  ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_SELECTABLE, false);
  ObjectSetInteger(0, BTN_SELL_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);

  ChartRedraw(0);
}

void DeleteStartButtons() {
  ObjectDelete(0, BTN_BUY_NAME);
  ObjectDelete(0, BTN_SELL_NAME);
  ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit() {
  trade.SetExpertMagicNumber(MagicNumber);
  trade.SetDeviationInPoints(SlippagePoints);
  g_mode = MODE_NONE;
  g_step = STEP_IDLE;
  g_nextMode = MODE_BUY_START;   // first cycle starts from BUY side
  // Initialize last TP deal time so we only react to NEW TP hits after EA start
  g_lastTPDealTime = 0;
  g_lastExitDealTime = 0;
  if (HistorySelect(0, TimeCurrent())) {
    int deals = HistoryDealsTotal();
    for (int i = deals - 1; i >= 0; i--) {
      ulong dealTicket = HistoryDealGetTicket(i);
      if (dealTicket == 0)
        continue;

      if (HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
        continue;

      long dealMagic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if ((int)dealMagic != MagicNumber)
        continue;

      ENUM_DEAL_ENTRY entry =
          (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if (entry != DEAL_ENTRY_OUT)
        continue;

      ENUM_DEAL_REASON reason =
          (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
      if (reason != DEAL_REASON_TP && reason != DEAL_REASON_SL)
        continue;

      datetime t = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      g_lastExitDealTime = t;
      if (reason == DEAL_REASON_TP)
        g_lastTPDealTime = t;
      break; // most recent TP/SL for this symbol
    }
  }
  g_ema14  = iMA(_Symbol, PERIOD_M1, 14, 0, MODE_EMA, PRICE_CLOSE);
  g_ema26  = iMA(_Symbol, PERIOD_M1, 26, 0, MODE_EMA, PRICE_CLOSE);
  g_ema50  = iMA(_Symbol, PERIOD_M1, 50, 0, MODE_EMA, PRICE_CLOSE);
  g_ema100 = iMA(_Symbol, PERIOD_M1, 100, 0, MODE_EMA, PRICE_CLOSE);
  g_ema200 = iMA(_Symbol, PERIOD_M1, 200, 0, MODE_EMA, PRICE_CLOSE);
  if (g_ema14 == INVALID_HANDLE || g_ema26 == INVALID_HANDLE ||
      g_ema50 == INVALID_HANDLE || g_ema100 == INVALID_HANDLE ||
      g_ema200 == INVALID_HANDLE) {
    Print("AutoBuySellHedging: failed to create M1 EMA handles. err=",
          GetLastError());
    return (INIT_FAILED);
  }

  Print("AutoBuySellHedgingManual initialized on symbol ", _Symbol,
        " | auto cycles starting from BUY.");
  return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
  DeleteStartButtons();
  if (g_ema14 != INVALID_HANDLE)
    IndicatorRelease(g_ema14);
  if (g_ema26 != INVALID_HANDLE)
    IndicatorRelease(g_ema26);
  if (g_ema50 != INVALID_HANDLE)
    IndicatorRelease(g_ema50);
  if (g_ema100 != INVALID_HANDLE)
    IndicatorRelease(g_ema100);
  if (g_ema200 != INVALID_HANDLE)
    IndicatorRelease(g_ema200);
}

//+------------------------------------------------------------------+
//| Trade transaction: detect manual order while running             |
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
  if (HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol)
    return;

  const ENUM_DEAL_ENTRY e =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
  if (e != DEAL_ENTRY_IN)
    return;

  const long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
  if ((int)magic == MagicNumber)
    return; // ignore EA deals

  // Manual order detected
  if (g_mode != MODE_NONE) {
    g_pauseAfterThisCycle = true;
    Print("[HedgingManual] Manual order detected while running -> will pause after TP/SL.");
  } else if (g_pausedUntilManual) {
    g_pausedUntilManual = false;
    g_pauseAfterThisCycle = false;
    Print("[HedgingManual] Resumed by manual order.");
  }
}

//+------------------------------------------------------------------+
//| Chart event: handle BUY / SELL button click                      |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam,
                  const string &sparam) {
  if (id != CHARTEVENT_OBJECT_CLICK)
    return;
  if (sparam != BTN_BUY_NAME && sparam != BTN_SELL_NAME)
    return;

  // Manual click should also resume EA if paused
  if (g_pausedUntilManual) {
    g_pausedUntilManual = false;
    g_pauseAfterThisCycle = false;
    Print("[HedgingManual] Resumed by manual button.");
  }

  string symbol = _Symbol;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
  double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
  double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

  double vol = MathMax(SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN), StartLot);
  double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
  if (step > 0.0)
    vol = MathRound(vol / step) * step;

  // Open with magic 0 so EA treats it as "manual" and starts cycle
  trade.SetExpertMagicNumber(0);
  trade.SetDeviationInPoints(SlippagePoints);

  if (!TrendFilterEmaM1Ok()) {
    Print("[HedgingManual] Button order skipped: M1 EMA stack not aligned.");
    trade.SetExpertMagicNumber(MagicNumber);
    ChartRedraw(0);
    return;
  }

  if (sparam == BTN_BUY_NAME) {
    if (trade.Buy(vol, symbol, ask, 0.0, 0.0, "Hedging Start BUY")) {
      Print("[HedgingManual] BUY button: market BUY ", vol,
            " opened. Cycle will start on next tick.");
    } else {
      Print("[HedgingManual] BUY button failed. Error=", GetLastError());
    }
  } else if (sparam == BTN_SELL_NAME) {
    if (trade.Sell(vol, symbol, bid, 0.0, 0.0, "Hedging Start SELL")) {
      Print("[HedgingManual] SELL button: market SELL ", vol,
            " opened. Cycle will start on next tick.");
    } else {
      Print("[HedgingManual] SELL button failed. Error=", GetLastError());
    }
  }

  trade.SetExpertMagicNumber(MagicNumber);
  ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Expert tick                                                       |
//+------------------------------------------------------------------+
void OnTick() {
  string symbol = _Symbol;
  double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
  int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

  // If paused, only resume when user opens a new manual BUY or SELL
  if (g_pausedUntilManual) {
    ulong bt = 0, st = 0;
    if (!FindManualPosition(POSITION_TYPE_BUY, bt) &&
        !FindManualPosition(POSITION_TYPE_SELL, st)) {
      return;
    }
    // manual position exists -> allow EA to run again
    g_pausedUntilManual = false;
    g_pauseAfterThisCycle = false;
  }

  // Keep SL/TP aligned per side after pending triggers
  EnforceAnchorsOnEAPositions();

  // 1) If any TP/SL is hit -> close everything and reset (both modes)
  bool isTP = false;
  if (AnyExitHit(isTP)) {
    Print("[HedgingManual] ", (isTP ? "TP" : "SL"),
          " reached. Closing all positions and orders, resetting state.");
    CloseAllAndReset();
    if (g_pauseAfterThisCycle) {
      g_pausedUntilManual = true;
      g_pauseAfterThisCycle = false;
      Print("[HedgingManual] Paused until next manual BUY/SELL.");
    }
    return;
  }

  // 1b) If user closed all positions/orders manually -> reset so next manual
  // open starts a new cycle
  if (g_mode != MODE_NONE) {
    int posCount = 0, ordCount = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if (t == 0 || !PositionSelectByTicket(t))
        continue;
      if (PositionGetString(POSITION_SYMBOL) == symbol)
        posCount++;
    }
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong t = OrderGetTicket(i);
      if (t == 0 || !OrderSelect(t))
        continue;
      if (OrderGetString(ORDER_SYMBOL) == symbol)
        ordCount++;
    }
    if (posCount == 0 && ordCount == 0) {
      g_mode = MODE_NONE;
      g_step = STEP_IDLE;
      Print("[HedgingManual] All closed manually. Reset. Ready for new manual "
            "open.");
    }
  }

  // 2) If no active cycle, start a new one (manual or auto)
  if (g_mode == MODE_NONE) {
    ulong buyTicket = 0;
    ulong sellTicket = 0;
    bool hasManualBuy = FindManualPosition(POSITION_TYPE_BUY, buyTicket);
    bool hasManualSell = FindManualPosition(POSITION_TYPE_SELL, sellTicket);

    // 2a) If user manually opened exactly one side, respect that (old behavior)
    if (hasManualBuy && !hasManualSell) {
      if (TrendFilterEmaM1Ok())
        StartBuyCycle(buyTicket);
    } else if (hasManualSell && !hasManualBuy) {
      if (TrendFilterEmaM1Ok())
        StartSellCycle(sellTicket);
    } else if (!hasManualBuy && !hasManualSell) {
      // 2b) No manual start -> auto open first order with EA magic
      string symbol = _Symbol;
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double lot = Lots_Step1; // first order lot = Step1 (0.01 by default)

      trade.SetExpertMagicNumber(MagicNumber);
      trade.SetDeviationInPoints(SlippagePoints);

      ulong newTicket = 0;

      if (!TrendFilterEmaM1Ok()) {
        // wait until M1 EMA stack aligns
        return;
      }

      if (g_nextMode == MODE_BUY_START) {
        if (trade.Buy(lot, symbol, ask, 0.0, 0.0, "AutoStart BUY")) {
          // find the newly opened BUY position (EA magic, lot = Lots_Step1)
          int totalPos = PositionsTotal();
          for (int i = totalPos - 1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if (t == 0 || !PositionSelectByTicket(t))
              continue;
            if (PositionGetString(POSITION_SYMBOL) != symbol)
              continue;
            if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
              continue;
            if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) !=
                POSITION_TYPE_BUY)
              continue;
            double vol = PositionGetDouble(POSITION_VOLUME);
            if (MathAbs(vol - Lots_Step1) > 1e-5)
              continue;
            newTicket = t;
            break;
          }
          if (newTicket != 0)
            StartBuyCycle(newTicket);
          Print("[Auto] Started BUY cycle automatically.");
        }
      } else { // MODE_SELL_START
        if (trade.Sell(lot, symbol, bid, 0.0, 0.0, "AutoStart SELL")) {
          // find the newly opened SELL position (EA magic, lot = Lots_Step1)
          int totalPos = PositionsTotal();
          for (int i = totalPos - 1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if (t == 0 || !PositionSelectByTicket(t))
              continue;
            if (PositionGetString(POSITION_SYMBOL) != symbol)
              continue;
            if ((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
              continue;
            if ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) !=
                POSITION_TYPE_SELL)
              continue;
            double vol = PositionGetDouble(POSITION_VOLUME);
            if (MathAbs(vol - Lots_Step1) > 1e-5)
              continue;
            newTicket = t;
            break;
          }
          if (newTicket != 0)
            StartSellCycle(newTicket);
          Print("[Auto] Started SELL cycle automatically.");
        }
      }
    }

    // Old behavior: wait for Start*Cycle to run on next tick
    return;
  }

  // 3) Hedge sequence for active mode
  if (!TrendFilterEmaM1Ok())
    return; // no new pending hedge orders until M1 EMA stack aligns

  double entryPrice;

  trade.SetDeviationInPoints(SlippagePoints);
  trade.SetExpertMagicNumber(MagicNumber);

  if (g_mode == MODE_BUY_START) {
    // Order: BUY 0.01 -> SELL STOP 0.03 -> BUY STOP 0.06 -> SELL STOP 0.17 ->
    // BUY STOP 0.40 -> wait TP
    if (g_step == STEP_1) {
      bool hasSell1 = GetEAPosition(POSITION_TYPE_SELL, Lots_Step2, entryPrice);
      bool hasBuyStop1 = HasEAPending(ORDER_TYPE_BUY_STOP, Lots_Step3);
      if (hasSell1 && !hasBuyStop1) {
        double buyPrice = entryPrice + DistancePoints * point;
        buyPrice = NormalizeDouble(buyPrice, digits);
        double aSL = 0.0, aTP = 0.0;
        bool hasAnchor = FindAnchorForSide(POSITION_TYPE_BUY, aSL, aTP);
        if (!hasAnchor) {
          aSL = 0.0;
          aTP = NormalizeDouble(buyPrice + TPPoints * point, digits);
        }
        if (trade.BuyStop(Lots_Step3, buyPrice, symbol, aSL, aTP)) {
          Print("[HedgingManual] BUY-start: BUY STOP #1 (", Lots_Step3, ") at ",
                buyPrice);
          g_step = STEP_2;
        } else
          Print("[HedgingManual] BUY-start: failed BUY STOP #1. Error=",
                GetLastError());
      }
    } else if (g_step == STEP_2) {
      bool hasBuy2 = GetEAPosition(POSITION_TYPE_BUY, Lots_Step3, entryPrice);
      bool hasSellStop2 = HasEAPending(ORDER_TYPE_SELL_STOP, Lots_Step4);
      if (hasBuy2 && !hasSellStop2) {
        double sellPrice = entryPrice - DistancePoints * point;
        sellPrice = NormalizeDouble(sellPrice, digits);
        double aSL = 0.0, aTP = 0.0;
        bool hasAnchor = FindAnchorForSide(POSITION_TYPE_SELL, aSL, aTP);
        if (!hasAnchor) {
          aSL = 0.0;
          aTP = NormalizeDouble(sellPrice - TPPoints * point, digits);
        }
        if (trade.SellStop(Lots_Step4, sellPrice, symbol, aSL, aTP)) {
          Print("[HedgingManual] BUY-start: SELL STOP #2 (", Lots_Step4,
                ") at ", sellPrice);
          g_step = STEP_3;
        } else
          Print("[HedgingManual] BUY-start: failed SELL STOP #2. Error=",
                GetLastError());
      }
    } else if (g_step == STEP_3) {
      bool hasSell3 = GetEAPosition(POSITION_TYPE_SELL, Lots_Step4, entryPrice);
      bool hasBuyStop3 = HasEAPending(ORDER_TYPE_BUY_STOP, Lots_Step5);
      if (hasSell3 && !hasBuyStop3) {
        double buyPrice = entryPrice + DistancePoints * point;
        buyPrice = NormalizeDouble(buyPrice, digits);
        double aSL = 0.0, aTP = 0.0;
        bool hasAnchor = FindAnchorForSide(POSITION_TYPE_BUY, aSL, aTP);
        if (!hasAnchor) {
          aSL = 0.0;
          aTP = NormalizeDouble(buyPrice + TPPoints * point, digits);
        }
        if (trade.BuyStop(Lots_Step5, buyPrice, symbol, aSL, aTP)) {
          Print("[HedgingManual] BUY-start: BUY STOP #2 (", Lots_Step5, ") at ",
                buyPrice);
          g_step = STEP_4;
        } else
          Print("[HedgingManual] BUY-start: failed BUY STOP #2. Error=",
                GetLastError());
      }
    } else if (g_step == STEP_4) {
      // Final: BUY 0.40 in market; wait for TP (handled at top)
    }
  } else if (g_mode == MODE_SELL_START) {
    // Order: SELL 0.01 -> BUY STOP 0.03 -> SELL STOP 0.06 -> BUY STOP 0.17 ->
    // SELL STOP 0.40 -> wait TP (mirror of BUY)
    if (g_step == STEP_1) {
      bool hasBuy1 = GetEAPosition(POSITION_TYPE_BUY, Lots_Step2, entryPrice);
      bool hasSellStop1 = HasEAPending(ORDER_TYPE_SELL_STOP, Lots_Step3);
      if (hasBuy1 && !hasSellStop1) {
        double sellPrice = entryPrice - DistancePoints * point;
        sellPrice = NormalizeDouble(sellPrice, digits);
        double aSL = 0.0, aTP = 0.0;
        bool hasAnchor = FindAnchorForSide(POSITION_TYPE_SELL, aSL, aTP);
        if (!hasAnchor) {
          aSL = 0.0;
          aTP = NormalizeDouble(sellPrice - TPPoints * point, digits);
        }
        if (trade.SellStop(Lots_Step3, sellPrice, symbol, aSL, aTP)) {
          Print("[HedgingManual] SELL-start: SELL STOP #1 (", Lots_Step3,
                ") at ", sellPrice);
          g_step = STEP_2;
        } else
          Print("[HedgingManual] SELL-start: failed SELL STOP #1. Error=",
                GetLastError());
      }
    } else if (g_step == STEP_2) {
      bool hasSell2 = GetEAPosition(POSITION_TYPE_SELL, Lots_Step3, entryPrice);
      bool hasBuyStop2 = HasEAPending(ORDER_TYPE_BUY_STOP, Lots_Step4);
      if (hasSell2 && !hasBuyStop2) {
        double buyPrice = entryPrice + DistancePoints * point;
        buyPrice = NormalizeDouble(buyPrice, digits);
        double aSL = 0.0, aTP = 0.0;
        bool hasAnchor = FindAnchorForSide(POSITION_TYPE_BUY, aSL, aTP);
        if (!hasAnchor) {
          aSL = 0.0;
          aTP = NormalizeDouble(buyPrice + TPPoints * point, digits);
        }
        if (trade.BuyStop(Lots_Step4, buyPrice, symbol, aSL, aTP)) {
          Print("[HedgingManual] SELL-start: BUY STOP #2 (", Lots_Step4,
                ") at ", buyPrice);
          g_step = STEP_3;
        } else
          Print("[HedgingManual] SELL-start: failed BUY STOP #2. Error=",
                GetLastError());
      }
    } else if (g_step == STEP_3) {
      bool hasBuy3 = GetEAPosition(POSITION_TYPE_BUY, Lots_Step4, entryPrice);
      bool hasSellStop3 = HasEAPending(ORDER_TYPE_SELL_STOP, Lots_Step5);
      if (hasBuy3 && !hasSellStop3) {
        double sellPrice = entryPrice - DistancePoints * point;
        sellPrice = NormalizeDouble(sellPrice, digits);
        double aSL = 0.0, aTP = 0.0;
        bool hasAnchor = FindAnchorForSide(POSITION_TYPE_SELL, aSL, aTP);
        if (!hasAnchor) {
          aSL = 0.0;
          aTP = NormalizeDouble(sellPrice - TPPoints * point, digits);
        }
        if (trade.SellStop(Lots_Step5, sellPrice, symbol, aSL, aTP)) {
          Print("[HedgingManual] SELL-start: SELL STOP #2 (", Lots_Step5,
                ") at ", sellPrice);
          g_step = STEP_4;
        } else
          Print("[HedgingManual] SELL-start: failed SELL STOP #2. Error=",
                GetLastError());
      }
    } else if (g_step == STEP_4) {
      // Final: SELL 0.40 in market; wait for TP (handled at top)
    }
  }
}
