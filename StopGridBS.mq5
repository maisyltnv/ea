//+------------------------------------------------------------------+
//| StopGridBS.mq5                                                   |
//| ຮອບ: ເປີດ market 1 ໄມ້ + BUY STOP / SELL STOP ຂັ້ນໄດ ສອງຝັ່ງ ວາງຄັ້ງດຽວ  |
//| ປິດທຸກຢ່າງເມື່ອກຳໄລລອຍລວມ >= TargetProfitUSD → ຮອບໃໝ່ ເລີ່ມຝັ່ງທີ່ຊະນະ    |
//+------------------------------------------------------------------+
#property copyright "maisyltnv"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum SG_SIDE { SG_BUY = 0, SG_SELL = 1 };

input SG_SIDE FirstSide        = SG_BUY;  // ໄມ້ market ຂອງຮອບທຳອິດ
input double  LotSize          = 0.01;    // lot ທຸກໄມ້
input int     StopsPerSide     = 11;      // ຈຳນວນ stop ຕໍ່ຝັ່ງ
input int     StepPoints       = 200;     // ຫ່າງລະຫວ່າງ stop (ຈຸດ)
input double  TargetProfitUSD  = 100;     // ກຳໄລລອຍລວມ (ທຸກໄມ້ເປີດ) → ປິດໝົດ ເລີ່ມຮອບໃໝ່
input long    MagicNumber      = 8802;
input int     SlippagePoints   = 30;

CTrade  trade;
double  g_point  = 0.0;
int     g_digits = 0;
SG_SIDE g_nextSide;          // ຝັ່ງ market ຂອງຮອບຕໍ່ໄປ
string  g_gvNextSide;

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

bool IsMyPosition(const ulong tk)
{
   if (tk == 0 || !PositionSelectByTicket(tk)) return false;
   if (PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   return (PositionGetInteger(POSITION_MAGIC) == MagicNumber);
}

bool IsMyOrder(const ulong tk)
{
   if (tk == 0 || !OrderSelect(tk)) return false;
   if (OrderGetString(ORDER_SYMBOL) != _Symbol) return false;
   return (OrderGetInteger(ORDER_MAGIC) == MagicNumber);
}

int CountMyPositions()
{
   int n = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) if (IsMyPosition(PositionGetTicket(i))) n++;
   return n;
}

int CountMyOrders()
{
   int n = 0;
   for (int i = OrdersTotal() - 1; i >= 0; i--) if (IsMyOrder(OrderGetTicket(i))) n++;
   return n;
}

// ກຳໄລລອຍ (profit+swap) ຂອງໄມ້ EA — ລວມ ແລະ ແຍກຝັ່ງ
double FloatingPL(double &buyPL, double &sellPL)
{
   buyPL = 0.0;
   sellPL = 0.0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong tk = PositionGetTicket(i);
      if (!IsMyPosition(tk)) continue;
      const double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buyPL += p;
      else                                                        sellPL += p;
   }
   return buyPL + sellPL;
}

void CloseAll()
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong tk = PositionGetTicket(i);
      if (IsMyPosition(tk) && !trade.PositionClose(tk))
         Print("Close failed tk=", tk, " ", trade.ResultRetcodeDescription());
   }
   for (int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong tk = OrderGetTicket(i);
      if (IsMyOrder(tk) && !trade.OrderDelete(tk))
         Print("Delete failed tk=", tk, " ", trade.ResultRetcodeDescription());
   }
}

void SaveNextSide(const SG_SIDE s)
{
   g_nextSide = s;
   GlobalVariableSet(g_gvNextSide, (double)(int)s);
}

//+------------------------------------------------------------------+
// ຮອບໃໝ່: market 1 ໄມ້ + ຂັ້ນໄດ stop ສອງຝັ່ງ ທັງໝົດພ້ອມກັນ
void StartRound()
{
   const double lot = NormLot(LotSize);
   const string cmt = "SG round";
   bool ok;
   if (g_nextSide == SG_BUY) ok = trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, cmt);
   else                      ok = trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, cmt);
   if (!ok)
   {
      Print("Round open ", (g_nextSide == SG_BUY ? "BUY" : "SELL"), " failed: ", trade.ResultRetcodeDescription());
      return;
   }
   Print("Round started with ", (g_nextSide == SG_BUY ? "BUY" : "SELL"), " ", DoubleToString(lot, 2));

   const double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const int    stops = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double step  = StepPoints * g_point;
   const double minD  = (stops + 1) * g_point;

   for (int i = 1; i <= StopsPerSide; i++)
   {
      double pb = Norm(ask + step * i);
      if (pb - ask < minD) pb = Norm(ask + minD);
      if (!trade.BuyStop(lot, pb, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, cmt))
         Print("BuyStop ", i, " failed: ", trade.ResultRetcodeDescription());

      double ps = Norm(bid - step * i);
      if (bid - ps < minD) ps = Norm(bid - minD);
      if (!trade.SellStop(lot, ps, _Symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, cmt))
         Print("SellStop ", i, " failed: ", trade.ResultRetcodeDescription());
   }
}

void Process()
{
   double buyPL = 0.0, sellPL = 0.0;
   const double pl = FloatingPL(buyPL, sellPL);
   const int nPos = CountMyPositions();

   // TP ຮອບ → ປິດໝົດ, ຮອບໃໝ່ເລີ່ມຝັ່ງທີ່ຊະນະ
   if (nPos > 0 && TargetProfitUSD > 0 && pl >= TargetProfitUSD)
   {
      const SG_SIDE winner = (buyPL >= sellPL) ? SG_BUY : SG_SELL;
      Print("Target hit: ", DoubleToString(pl, 2), " USD (BUY ", DoubleToString(buyPL, 2),
            " / SELL ", DoubleToString(sellPL, 2), ") → close all, next round ",
            (winner == SG_BUY ? "BUY" : "SELL"));
      CloseAll();
      SaveNextSide(winner);
      return;                         // ຮອບໃໝ່ເລີ່ມ tick ຖັດໄປ ເມື່ອທຸກຢ່າງປິດແລ້ວ
   }

   // ບໍ່ມີຫຍັງເຫຼືອ → ຮອບໃໝ່
   if (nPos == 0 && CountMyOrders() == 0)
      StartRound();
}

void ShowStatus()
{
   double b = 0.0, s = 0.0;
   const double pl = FloatingPL(b, s);
   Comment("StopGridBS  magic " + (string)MagicNumber + "\n" +
           "Positions " + (string)CountMyPositions() + "  pendings " + (string)CountMyOrders() + "\n" +
           "Floating " + DoubleToString(pl, 2) + " USD (BUY " + DoubleToString(b, 2) +
           " / SELL " + DoubleToString(s, 2) + ")  target " + DoubleToString(TargetProfitUSD, 0) + "\n" +
           "Next round: " + (g_nextSide == SG_BUY ? "BUY" : "SELL"));
}

//+------------------------------------------------------------------+
int OnInit()
{
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_gvNextSide = "StopGridBS_NextSide_" + _Symbol + "_" + (string)MagicNumber;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   if (AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("ຄຳເຕືອນ: ບັນຊີບໍ່ແມ່ນ Hedging — EA ນີ້ຕ້ອງຖື BUY ແລະ SELL ພ້ອມກັນ");

   g_nextSide = FirstSide;
   if (GlobalVariableCheck(g_gvNextSide))
      g_nextSide = ((int)GlobalVariableGet(g_gvNextSide) == (int)SG_SELL) ? SG_SELL : SG_BUY;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { Comment(""); }

void OnTick()
{
   Process();
   ShowStatus();
}
//+------------------------------------------------------------------+
