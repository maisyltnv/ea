//+------------------------------------------------------------------+
//| Set the same SL/TP for all positions and pending orders          |
//+------------------------------------------------------------------+
#property strict

input double SL = 2475.0;
input double TP = 2440.0;

void OnStart()
{
   double newSL = SL;
   double newTP = TP;
   int modifiedCount = 0;
   
   Print("Starting modification: SL=", newSL, ", TP=", newTP);
   
   // Process all open positions
   int totalPositions = PositionsTotal();
   Print("Found ", totalPositions, " positions");
   
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionSelectByTicket(ticket))
         {
            string symbol = PositionGetString(POSITION_SYMBOL);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

            // Process all open positions (BUY/SELL)
            if(type == POSITION_TYPE_BUY || type == POSITION_TYPE_SELL)
            {
               // Normalize prices
               int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
               double normalizedSL = NormalizeDouble(newSL, digits);
               double normalizedTP = NormalizeDouble(newTP, digits);
               
               // Modify position using OrderSend with TRADE_ACTION_SLTP
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
                  Print("Position modified: Ticket=", ticket, ", Symbol=", symbol, ", Type=", EnumToString(type));
               }
               else
                  Print("Modify position failed for ticket ", ticket, ": ", result.retcode, " - ", result.comment);
            }
         }
      }
   }
   
   // Process all pending orders
   int totalOrders = OrdersTotal();
   Print("Found ", totalOrders, " pending orders");
   
   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderSelect(ticket))
         {
            string symbol = OrderGetString(ORDER_SYMBOL);
            ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            double priceOpen = OrderGetDouble(ORDER_PRICE_OPEN);

            // Process all pending orders
            if(type == ORDER_TYPE_BUY_LIMIT ||
               type == ORDER_TYPE_SELL_LIMIT ||
               type == ORDER_TYPE_BUY_STOP ||
               type == ORDER_TYPE_SELL_STOP)
            {
               // Normalize prices
               int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
               double normalizedSL = NormalizeDouble(newSL, digits);
               double normalizedTP = NormalizeDouble(newTP, digits);
               double normalizedPrice = NormalizeDouble(priceOpen, digits);
               
               // Modify pending order using OrderSend with TRADE_ACTION_MODIFY
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
                  Print("Pending order modified: Ticket=", ticket, ", Symbol=", symbol, ", Type=", EnumToString(type));
               }
               else
                  Print("Modify pending order failed for ticket ", ticket, ": ", result.retcode, " - ", result.comment);
            }
         }
      }
   }
   
   Print("Completed: Updated ", modifiedCount, " positions and pending orders.");
}
