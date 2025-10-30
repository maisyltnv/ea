//+------------------------------------------------------------------+
//|                                           ema5_buy_sell.mq5      |
//|                                    Expert Advisor for EMA 5      |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"
#property strict

//--- Input parameters
input int      InpMagicNumber = 123456;  // Magic number
input int      InpEMA_Period = 5;        // EMA Period
input double   InpLotSize = 0.01;        // Lot size
input int      InpStopLoss = 100;        // Stop Loss (points)
input int      InpTakeProfit = 200;      // Take Profit (points)
input bool     InpOncePerBar = true;     // Open position once per bar

//--- Global variables
int emaHandle;
double emaBuffer[];
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Create EMA indicator handle
   emaHandle = iMA(_Symbol, PERIOD_M1, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   
   if(emaHandle == INVALID_HANDLE)
   {
      Print("Error creating EMA indicator. Error code: ", GetLastError());
      return(INIT_FAILED);
   }
   
   ArraySetAsSeries(emaBuffer, true);
   
   Print("EA initialized successfully");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Release indicator handle
   if(emaHandle != INVALID_HANDLE)
      IndicatorRelease(emaHandle);
      
   Print("EA deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Check if we should open only once per bar
   if(InpOncePerBar)
   {
      datetime currentBarTime = iTime(_Symbol, PERIOD_M1, 0);
      if(currentBarTime == lastBarTime)
         return;
      lastBarTime = currentBarTime;
   }
   
   //--- Check if there are any open positions
   if(HasOpenPosition())
      return;
   
   //--- Get current EMA value
   if(CopyBuffer(emaHandle, 0, 0, 2, emaBuffer) <= 0)
   {
      Print("Error copying EMA buffer. Error code: ", GetLastError());
      return;
   }
   
   //--- Get current prices
   double currentClose = iClose(_Symbol, PERIOD_M1, 0);
   
   //--- Check for Buy signal: Price > EMA5
   if(currentClose > emaBuffer[0])
   {
      OpenBuyOrder();
   }
   //--- Check for Sell signal: Price < EMA5
   else if(currentClose < emaBuffer[0])
   {
      OpenSellOrder();
   }
}

//+------------------------------------------------------------------+
//| Check if there is an open position                               |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;
         
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Open Buy order                                                    |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   
   ZeroMemory(request);
   ZeroMemory(result);
   
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = InpStopLoss > 0 ? price - InpStopLoss * _Point : 0;
   double tp = InpTakeProfit > 0 ? price + InpTakeProfit * _Point : 0;
   
   //--- Normalize prices
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = InpLotSize;
   request.type = ORDER_TYPE_BUY;
   request.price = price;
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = InpMagicNumber;
   request.comment = "EMA5 Buy";
   
   if(!OrderSend(request, result))
   {
      Print("Buy order failed. Error code: ", GetLastError(), 
            ", Result: ", result.retcode);
   }
   else
   {
      Print("Buy order opened successfully. Ticket: ", result.order);
   }
}

//+------------------------------------------------------------------+
//| Open Sell order                                                   |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   
   ZeroMemory(request);
   ZeroMemory(result);
   
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = InpStopLoss > 0 ? price + InpStopLoss * _Point : 0;
   double tp = InpTakeProfit > 0 ? price - InpTakeProfit * _Point : 0;
   
   //--- Normalize prices
   sl = NormalizeDouble(sl, _Digits);
   tp = NormalizeDouble(tp, _Digits);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = InpLotSize;
   request.type = ORDER_TYPE_SELL;
   request.price = price;
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = InpMagicNumber;
   request.comment = "EMA5 Sell";
   
   if(!OrderSend(request, result))
   {
      Print("Sell order failed. Error code: ", GetLastError(), 
            ", Result: ", result.retcode);
   }
   else
   {
      Print("Sell order opened successfully. Ticket: ", result.order);
   }
}
//+------------------------------------------------------------------+

