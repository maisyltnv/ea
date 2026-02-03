//+------------------------------------------------------------------+
//| Set SL/TP from FIRST order open price, apply to all               |
//| First order: SELL -> SL = open + SLPoints, TP = open - TPPoints   |
//|              BUY  -> SL = open - SLPoints, TP = open + TPPoints   |
//+------------------------------------------------------------------+
#property strict

input int SLPoints = 1500;   // SL distance from first open price (points)
input int TPPoints = 500;    // TP distance from first open price (points)

void OnStart()
{
   int modifiedCount = 0;
   
   // --- Step 1: Find the FIRST order (earliest by time) ---
   datetime firstTime = 0;
   double firstOpenPrice = 0;
   string firstSymbol = "";
   bool firstIsBuy = true;
   bool foundFirst = false;
   
   // Check positions
   int totalPositions = PositionsTotal();
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(firstTime == 0 || posTime < firstTime)
         {
            firstTime = posTime;
            firstOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            firstSymbol = PositionGetString(POSITION_SYMBOL);
            firstIsBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
            foundFirst = true;
         }
      }
   }
   
   // Check pending orders
   int totalOrders = OrdersTotal();
   for(int i = 0; i < totalOrders; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderSelect(ticket))
      {
         ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(otype == ORDER_TYPE_BUY_LIMIT || otype == ORDER_TYPE_SELL_LIMIT ||
            otype == ORDER_TYPE_BUY_STOP || otype == ORDER_TYPE_SELL_STOP)
         {
            datetime orderTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
            if(firstTime == 0 || orderTime < firstTime)
            {
               firstTime = orderTime;
               firstOpenPrice = OrderGetDouble(ORDER_PRICE_OPEN);
               firstSymbol = OrderGetString(ORDER_SYMBOL);
               firstIsBuy = (otype == ORDER_TYPE_BUY_LIMIT || otype == ORDER_TYPE_BUY_STOP);
               foundFirst = true;
            }
         }
      }
   }
   
   if(!foundFirst)
   {
      Print("No positions or pending orders found.");
      return;
   }
   
   // --- Step 2: Calculate SL and TP from first order ---
   double point = SymbolInfoDouble(firstSymbol, SYMBOL_POINT);
   double baseSL, baseTP;
   if(firstIsBuy)
   {
      baseSL = firstOpenPrice - (SLPoints * point);
      baseTP = firstOpenPrice + (TPPoints * point);
   }
   else
   {
      baseSL = firstOpenPrice + (SLPoints * point);
      baseTP = firstOpenPrice - (TPPoints * point);
   }
   
   Print("First order: ", firstIsBuy ? "BUY" : "SELL", " Open=", firstOpenPrice, " Time=", TimeToString(firstTime));
   Print("Calculated SL=", baseSL, " TP=", baseTP, " (applying to all)");
   
   // --- Step 3: Apply same SL/TP to ALL positions ---
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         string symbol = PositionGetString(POSITION_SYMBOL);
         int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
         double normalizedSL = NormalizeDouble(baseSL, digits);
         double normalizedTP = NormalizeDouble(baseTP, digits);
         
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         request.action = TRADE_ACTION_SLTP;
         request.position = ticket;
         request.symbol = symbol;
         request.sl = normalizedSL;
         request.tp = normalizedTP;
         
         if(OrderSend(request, result))
         {
            modifiedCount++;
            Print("Position: Ticket=", ticket, " SL=", normalizedSL, " TP=", normalizedTP);
         }
         else
            Print("Failed position ", ticket, ": ", result.retcode, " - ", result.comment);
      }
   }
   
   // --- Step 4: Apply same SL/TP to ALL pending orders ---
   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderSelect(ticket))
      {
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT &&
            type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP)
            continue;
         
         string symbol = OrderGetString(ORDER_SYMBOL);
         double priceOpen = OrderGetDouble(ORDER_PRICE_OPEN);
         int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
         double normalizedSL = NormalizeDouble(baseSL, digits);
         double normalizedTP = NormalizeDouble(baseTP, digits);
         double normalizedPrice = NormalizeDouble(priceOpen, digits);
         
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         request.action = TRADE_ACTION_MODIFY;
         request.order = ticket;
         request.symbol = symbol;
         request.price = normalizedPrice;
         request.sl = normalizedSL;
         request.tp = normalizedTP;
         
         if(OrderSend(request, result))
         {
            modifiedCount++;
            Print("Order: Ticket=", ticket, " SL=", normalizedSL, " TP=", normalizedTP);
         }
         else
            Print("Failed order ", ticket, ": ", result.retcode, " - ", result.comment);
      }
   }
   
   Print("Done: Updated ", modifiedCount, " positions/orders (SL/TP from first order).");
}
