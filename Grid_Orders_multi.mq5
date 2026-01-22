//+------------------------------------------------------------------+
//| Grid Orders Script                                                |
//| Places multiple pending BUY or SELL orders in a grid pattern     |
//+------------------------------------------------------------------+
#property strict

enum ENUM_GRID_ORDER_TYPE
{
   GRID_ORDER_BUY = 0,   // BUY LIMIT (orders below current price)
   GRID_ORDER_SELL = 1   // SELL LIMIT (orders above current price)
};

input string TradeSymbol = "XAUUSDu";    // Symbol to trade (XAUUSDu, XAUUSD, GOLD, etc.)
input ENUM_GRID_ORDER_TYPE OrderType = GRID_ORDER_BUY;  // Order Type: 0=BUY LIMIT, 1=SELL LIMIT
input double StartPrice = 4570;           // Starting price for first order (e.g. 4461.0 for exact price, 0 = auto calculate from current price)
input int    NumberOfOrders = 8;          // Number of orders to place
input int    GridSpacingPoints = 400;     // Distance between orders (points)
input int    TPPoints = 400;              // TP distance from first order (points)
input int    SLPoints = 400;              // SL distance from last order (points)
input double LotSize = 0.01;              // Base lot size (first order). Each subsequent order increases by this amount
input int    MagicNumber = 123456;        // Magic number for orders

void OnStart()
{
   // Show immediate alert that script started
   Alert("Grid Buy Orders Script - Starting...");
   
   // Use input symbol or current chart symbol
   string symbol = TradeSymbol;
   if(symbol == "" || symbol == "0")
   {
      symbol = _Symbol;
   }
   
   // Convert to uppercase for consistency
   StringToUpper(symbol);
   
   Print("========================================");
   Print("=== Grid Buy Orders Script Started ===");
   Print("========================================");
   Print("Symbol: ", symbol);
   Print("Time: ", TimeToString(TimeCurrent()));
   
   // Check if AutoTrading is enabled
   bool terminalTradeAllowed = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
   bool accountTradeExpert = AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
   
   Print("Terminal trade allowed: ", terminalTradeAllowed);
   Print("Account trade expert: ", accountTradeExpert);
   
   if(!terminalTradeAllowed)
   {
      Alert("Error: AutoTrading is disabled in terminal settings! Please enable AutoTrading button.");
      Print("Error: AutoTrading is disabled in terminal settings!");
      return;
   }
   
   if(!accountTradeExpert)
   {
      Alert("Error: AutoTrading is disabled for this account! Please enable in account settings.");
      Print("Error: AutoTrading is disabled for this account!");
      return;
   }
   
   // Allow any symbol (EURUSD, XAUUSD, etc.)
   string symbolUpper = symbol;
   StringToUpper(symbolUpper);
   
   Print("✓ Symbol accepted: ", symbol);
   
   // Check if symbol is selectable
   if(!SymbolSelect(symbol, true))
   {
      Print("Warning: Symbol ", symbol, " not found. Searching for similar symbols...");
      
      // Try common gold symbol variations
      string goldSymbols[] = {"XAUUSDu", "XAUUSD", "GOLD", "XAUUSD.", "XAU/USD", "GOLD/USD", "XAUUSDm", "XAUUSDc"};
      bool found = false;
      
      for(int s = 0; s < ArraySize(goldSymbols); s++)
      {
         if(SymbolSelect(goldSymbols[s], true))
         {
            symbol = goldSymbols[s];
            Print("Found symbol: ", symbol);
            found = true;
            break;
         }
      }
      
      if(!found)
      {
         // Try using current chart symbol
         string chartSymbol = _Symbol;
         if(SymbolSelect(chartSymbol, true))
         {
            symbol = chartSymbol;
            Print("Using chart symbol: ", symbol);
            found = true;
         }
      }
      
      if(!found)
      {
         Alert("Error: Cannot find gold symbol! Please check Market Watch and specify correct symbol name.");
         Print("Error: Cannot find gold symbol! Please check Market Watch.");
         Print("Common symbols: XAUUSDu, XAUUSD, GOLD");
         return;
      }
   }
   
   // Check if symbol is tradeable
   long tradeMode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   Print("Symbol trade mode: ", tradeMode);
   
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Alert("Error: Symbol ", symbol, " trading is disabled!");
      Print("Error: Symbol ", symbol, " trading is disabled!");
      return;
   }
   
   // Get price info - try both BID and ASK
   double currentBid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(symbol, SYMBOL_ASK);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   
   Print("Symbol info:");
   Print("  Bid: ", currentBid);
   Print("  Ask: ", currentAsk);
   Print("  Digits: ", digits);
   Print("  Point: ", point);
   Print("  Tick Size: ", tickSize);
   
   // Use BID for buy limit orders
   double currentPrice = currentBid;
   
   if(currentPrice <= 0)
   {
      // Try using ASK if BID is 0
      if(currentAsk > 0)
      {
         currentPrice = currentAsk;
         Print("BID was 0, using ASK instead: ", currentPrice);
      }
      else
      {
         Alert("Error: Cannot get current price for ", symbol, ". Bid = ", currentBid, ", Ask = ", currentAsk);
         Print("Error: Cannot get current price for ", symbol, ". Bid = ", currentBid, ", Ask = ", currentAsk);
         return;
      }
   }
   
   if(point <= 0)
   {
      Alert("Error: Invalid point value for ", symbol, ". Point = ", point);
      Print("Error: Invalid point value for ", symbol, ". Point = ", point);
      return;
   }
   
   Print("Using current price: ", currentPrice);
   Print("Order type: ", (OrderType == GRID_ORDER_BUY ? "BUY LIMIT" : "SELL LIMIT"));
   
   // Calculate starting price based on order type
   double startPrice;
   double firstOrderPrice;
   double lastOrderPrice;
   double tpPrice;
   double slPrice;
   
   // If StartPrice is specified (> 0), use it directly; otherwise use default distance
   if(StartPrice > 0.0)
   {
      // Use specified price directly
      startPrice = NormalizeDouble(StartPrice, digits);
   }
   else
   {
      // Default behavior: calculate from current price
      if(OrderType == GRID_ORDER_BUY)
      {
         // BUY LIMIT: orders below current price (default 1000 points)
         startPrice = currentPrice - (1000 * point);
      }
      else
      {
         // SELL LIMIT: orders above current price (default 1000 points)
         startPrice = currentPrice + (1000 * point);
      }
      startPrice = NormalizeDouble(startPrice, digits);
   }
   
   if(OrderType == GRID_ORDER_BUY)
   {
      // First order (highest price) and last order (lowest price)
      firstOrderPrice = startPrice;  // First order (i=0)
      lastOrderPrice = startPrice - ((NumberOfOrders - 1) * GridSpacingPoints * point);
      lastOrderPrice = NormalizeDouble(lastOrderPrice, digits);
      
      // For BUY: TP above entry, SL below entry
      tpPrice = firstOrderPrice + (TPPoints * point);
      slPrice = lastOrderPrice - (SLPoints * point);
   }
   else // SELL LIMIT
   {
      // First order (lowest price) and last order (highest price)
      firstOrderPrice = startPrice;  // First order (i=0)
      lastOrderPrice = startPrice + ((NumberOfOrders - 1) * GridSpacingPoints * point);
      lastOrderPrice = NormalizeDouble(lastOrderPrice, digits);
      
      // For SELL: TP below entry, SL above entry
      tpPrice = firstOrderPrice - (TPPoints * point);
      slPrice = lastOrderPrice + (SLPoints * point);
   }
   
   tpPrice = NormalizeDouble(tpPrice, digits);
   slPrice = NormalizeDouble(slPrice, digits);
   
   Print("Current price: ", currentPrice);
   if(StartPrice > 0.0)
      Print("Starting price (specified): ", startPrice);
   else
      Print("Starting price (calculated from current price): ", startPrice);
   Print("First order price: ", firstOrderPrice);
   Print("Last order price: ", lastOrderPrice);
   Print("TP for all orders: ", tpPrice, " (", TPPoints, " points from first order)");
   Print("SL for all orders: ", slPrice, " (", SLPoints, " points from last order)");
   Print("Grid spacing: ", GridSpacingPoints, " points = ", (GridSpacingPoints * point), " price units");
   Print("Base lot size: ", LotSize, " (each order increases by ", LotSize, ": order 1 = ", LotSize, ", order 2 = ", (2*LotSize), ", etc.)");
   Print("Placing ", NumberOfOrders, " ", (OrderType == GRID_ORDER_BUY ? "BUY LIMIT" : "SELL LIMIT"), " orders...");
   
   int successCount = 0;
   int failCount = 0;
   int skippedCount = 0;
   
   // Place orders in grid pattern
   Print("=== Starting order placement loop ===");
   for(int i = 0; i < NumberOfOrders; i++)
   {
      // Calculate price for this order
      double orderPrice;
      if(OrderType == GRID_ORDER_BUY)
      {
         // BUY: each order is lower than the previous
         orderPrice = startPrice - (i * GridSpacingPoints * point);
      }
      else
      {
         // SELL: each order is higher than the previous
         orderPrice = startPrice + (i * GridSpacingPoints * point);
      }
      orderPrice = NormalizeDouble(orderPrice, digits);
      
      // Place order
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      // Normalize volume first - calculate lot size for this order (incremental: order 1 = 0.01, order 2 = 0.02, etc.)
      double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      double orderLotSize = (i + 1) * LotSize;  // Order 1 = 0.01, Order 2 = 0.02, Order 3 = 0.03, etc.
      double normalizedVolume = MathMax(minLot, MathMin(maxLot, MathFloor(orderLotSize / lotStep) * lotStep));
      
      // Get filling mode
      int fillingMode = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
      ENUM_ORDER_TYPE_FILLING orderFilling = ORDER_FILLING_FOK;
      
      // Determine appropriate filling mode
      if((fillingMode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
         orderFilling = ORDER_FILLING_FOK;
      else if((fillingMode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
         orderFilling = ORDER_FILLING_IOC;
      else
         orderFilling = ORDER_FILLING_RETURN;
      
      request.action = TRADE_ACTION_PENDING;
      request.symbol = symbol;
      request.volume = normalizedVolume;
      request.type = (OrderType == GRID_ORDER_BUY) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
      request.price = orderPrice;
      request.tp = tpPrice;  // TP for all orders (from first order)
      request.sl = slPrice;  // SL for all orders (from last order)
      request.magic = MagicNumber;
      request.comment = (OrderType == GRID_ORDER_BUY ? "Grid Buy " : "Grid Sell ") + IntegerToString(i + 1);
      request.type_filling = orderFilling;
      request.type_time = ORDER_TIME_GTC;
      
      // Check stop level
      long stopLevel = (long)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
      double minDistance = stopLevel * point;
      
      Print("Order ", i + 1, " - Price: ", orderPrice, ", Ask: ", ask, ", Bid: ", bid, ", StopLevel: ", stopLevel);
      
      // Check if price is valid for order type
      bool priceValid = true;
      if(OrderType == GRID_ORDER_BUY)
      {
         // BUY LIMIT: price must be below current ask
         if(orderPrice >= ask - minDistance)
         {
            Print("Order ", i + 1, " skipped: Price ", orderPrice, " is too close to current ask (", ask, "). Min distance needed: ", minDistance);
            priceValid = false;
         }
      }
      else
      {
         // SELL LIMIT: price must be above current bid
         if(orderPrice <= bid + minDistance)
         {
            Print("Order ", i + 1, " skipped: Price ", orderPrice, " is too close to current bid (", bid, "). Min distance needed: ", minDistance);
            priceValid = false;
         }
      }
      
      if(!priceValid)
      {
         skippedCount++;
         failCount++;
         continue;
      }
      
      Print("Attempting to place order ", i + 1, " at price: ", orderPrice, ", Volume: ", request.volume, " (lot size: ", orderLotSize, ")");
      Print("  TP: ", request.tp, " | SL: ", request.sl);
      Print("  Request details: Symbol=", request.symbol, ", Type=", EnumToString(request.type), ", Filling=", EnumToString(request.type_filling));
      
      bool orderResult = OrderSend(request, result);
      
      if(orderResult)
      {
         successCount++;
         Print("✓ Order ", i + 1, " placed successfully!");
         Print("  Ticket: ", result.order);
         Print("  Deal: ", result.deal);
         Print("  Volume: ", result.volume);
         Print("  Price: ", result.price);
         Print("  Retcode: ", result.retcode);
      }
      else
      {
         failCount++;
         Print("✗ Order ", i + 1, " FAILED!");
         Print("  Retcode: ", result.retcode);
         Print("  Comment: ", result.comment);
         Print("  Request ID: ", result.request_id);
         Print("  Last Error: ", GetLastError());
         
         // Show detailed error message
         string errorMsg = "Unknown error";
         switch(result.retcode)
         {
            case 10004: errorMsg = "TRADE_RETCODE_REQUOTE"; break;
            case 10006: errorMsg = "TRADE_RETCODE_REJECT"; break;
            case 10007: errorMsg = "TRADE_RETCODE_CANCEL"; break;
            case 10008: errorMsg = "TRADE_RETCODE_PLACED"; break;
            case 10009: errorMsg = "TRADE_RETCODE_DONE"; break;
            case 10010: errorMsg = "TRADE_RETCODE_DONE_PARTIAL"; break;
            case 10011: errorMsg = "TRADE_RETCODE_ERROR"; break;
            case 10012: errorMsg = "TRADE_RETCODE_TIMEOUT"; break;
            case 10013: errorMsg = "TRADE_RETCODE_INVALID"; break;
            case 10014: errorMsg = "TRADE_RETCODE_INVALID_VOLUME"; break;
            case 10015: errorMsg = "TRADE_RETCODE_INVALID_PRICE"; break;
            case 10016: errorMsg = "TRADE_RETCODE_INVALID_STOPS"; break;
            case 10017: errorMsg = "TRADE_RETCODE_TRADE_DISABLED"; break;
            case 10018: errorMsg = "TRADE_RETCODE_MARKET_CLOSED"; break;
            case 10019: errorMsg = "TRADE_RETCODE_NO_MONEY"; break;
            case 10020: errorMsg = "TRADE_RETCODE_PRICE_CHANGED"; break;
            case 10021: errorMsg = "TRADE_RETCODE_PRICE_OFF"; break;
            case 10022: errorMsg = "TRADE_RETCODE_INVALID_EXPIRATION"; break;
            case 10023: errorMsg = "TRADE_RETCODE_ORDER_CHANGED"; break;
            case 10024: errorMsg = "TRADE_RETCODE_TOO_MANY_REQUESTS"; break;
            case 10025: errorMsg = "TRADE_RETCODE_NO_CHANGES"; break;
            case 10026: errorMsg = "TRADE_RETCODE_SERVER_DISABLES_AT"; break;
            case 10027: errorMsg = "TRADE_RETCODE_CLIENT_DISABLES_AT"; break;
            case 10028: errorMsg = "TRADE_RETCODE_LOCKED"; break;
            case 10029: errorMsg = "TRADE_RETCODE_FROZEN"; break;
            case 10030: errorMsg = "TRADE_RETCODE_INVALID_FILL"; break;
            case 10031: errorMsg = "TRADE_RETCODE_CONNECTION"; break;
            case 10032: errorMsg = "TRADE_RETCODE_ONLY_REAL"; break;
            case 10033: errorMsg = "TRADE_RETCODE_LIMIT_ORDERS"; break;
            case 10034: errorMsg = "TRADE_RETCODE_LIMIT_VOLUME"; break;
            case 10035: errorMsg = "TRADE_RETCODE_INVALID_ORDER"; break;
            case 10036: errorMsg = "TRADE_RETCODE_POSITION_CLOSED"; break;
            default: errorMsg = "Error code: " + IntegerToString(result.retcode); break;
         }
         Print("  Error meaning: ", errorMsg);
      }
      
      // Small delay to avoid server overload
      Sleep(100);
   }
   
   Print("=== Grid placement completed ===");
   Print("Successful: ", successCount, " | Failed: ", failCount, " | Skipped: ", skippedCount);
   
   string summaryMsg = "Grid orders: " + IntegerToString(successCount) + " successful, " + IntegerToString(failCount) + " failed, " + IntegerToString(skippedCount) + " skipped";
   
   if(successCount > 0)
   {
      Alert("SUCCESS! ", summaryMsg);
      Print("SUCCESS! ", summaryMsg);
   }
   else if(failCount > 0)
   {
      Alert("FAILED! ", summaryMsg, " - Check Experts tab for error details");
      Print("FAILED! ", summaryMsg);
   }
   else
   {
      Alert("No orders attempted. Check the Experts tab for details.");
      Print("No orders attempted.");
   }
   
   Print("=== Script finished ===");
}

