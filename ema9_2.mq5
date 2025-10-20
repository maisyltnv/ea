//+------------------------------------------------------------------+
//|                                                     EMA9_EA.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

//--- Input parameters
input double LotSize = 0.01;           // Lot size
input int    MagicNumber = 123456;    // Magic number
input int    EMA_Period = 9;         // EMA period
input int    Slippage = 3;            // Slippage
input bool   TradeOnNewBar = true;    // Trade only on new bar
input int    SwingLookbackBars = 10;  // Bars to look back for swing high/low
input int    SwingSLBufferPoints = 50; // Buffer points added to swing SL (Buy: +50, Sell: -50)
input int    BreakevenTriggerPoints = 200; // Move SL to BE when profit >= this (points)
input int    BreakevenOffsetPoints  = 10;  // Offset from BE in points (+ for buy, - for sell)
input int    TrailTriggerPoints     = 500; // Start EMA9 trailing when profit >= this (points)
input int    TakeProfitPoints       = 500; // Fixed TP distance in points
input int    DailyProfitLimitPoints = 1000; // Stop new entries when today's net profit reaches this (points)

//--- Global variables
int ema_handle;
datetime last_bar_time = 0;
double current_ema = 0;

//--- Helper forward declarations
double GetRecentSwingLow(int lookbackBars);
double GetRecentSwingHigh(int lookbackBars);
double GetTodayNetProfitPoints();

//+------------------------------------------------------------------+
//| Find recent swing low over lookback bars                         |
//+------------------------------------------------------------------+
double GetRecentSwingLow(int lookbackBars)
{
    double lowBuffer[];
    ArraySetAsSeries(lowBuffer, true);
    if(CopyLow(_Symbol, PERIOD_M1, 1, lookbackBars, lowBuffer) <= 0)
        return 0.0;
    double swingLow = lowBuffer[0];
    for(int i = 1; i < ArraySize(lowBuffer); i++)
    {
        if(lowBuffer[i] < swingLow)
            swingLow = lowBuffer[i];
    }
    return swingLow;
}

//+------------------------------------------------------------------+
//| Find recent swing high over lookback bars                        |
//+------------------------------------------------------------------+
double GetRecentSwingHigh(int lookbackBars)
{
    double highBuffer[];
    ArraySetAsSeries(highBuffer, true);
    if(CopyHigh(_Symbol, PERIOD_M1, 1, lookbackBars, highBuffer) <= 0)
        return 0.0;
    double swingHigh = highBuffer[0];
    for(int i = 1; i < ArraySize(highBuffer); i++)
    {
        if(highBuffer[i] > swingHigh)
            swingHigh = highBuffer[i];
    }
    return swingHigh;
}

//+------------------------------------------------------------------+
//| Calculate today's net profit in points for this symbol/magic     |
//+------------------------------------------------------------------+
double GetTodayNetProfitPoints()
{
    datetime from, to;
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    dt.hour = 0; dt.min = 0; dt.sec = 0;
    from = StructToTime(dt);
    to = TimeCurrent();

    if(!HistorySelect(from, to))
        return 0.0;

    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double netPoints = 0.0;

    uint deals = HistoryDealsTotal();
    for(uint i = 0; i < deals; i++)
    {
        ulong dealTicket = HistoryDealGetTicket(i);
        if(dealTicket == 0)
            continue;

        string sym = (string)HistoryDealGetString(dealTicket, DEAL_SYMBOL);
        long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
        int type = (int)HistoryDealGetInteger(dealTicket, DEAL_TYPE);

        if(sym != _Symbol || magic != MagicNumber)
            continue;

        // Consider only closed position results (DEAL_PROFIT and DEAL_SWAP, DEAL_COMMISSION reflected in profit)
        double profitCurrency = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
        // Convert currency profit to approximate points using tick value if available
        double price = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
        double volume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);

        // Estimate points from profit: points = profit / (tickValue * volume) / (1/point)
        double tickValue = 0.0;
        double tickSize = 0.0;
        SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE, tickValue);
        SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE, tickSize);
        if(tickValue > 0.0 && tickSize > 0.0 && volume > 0.0)
        {
            double pointsFromProfit = (profitCurrency / (tickValue * volume)) * (tickSize / point);
            netPoints += pointsFromProfit;
        }
        else
        {
            // Fallback: skip if cannot compute reliably
        }
    }

    return netPoints;
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Create EMA handle
    ema_handle = iMA(_Symbol, PERIOD_M1, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
    
    if(ema_handle == INVALID_HANDLE)
    {
        Print("Error creating EMA indicator handle");
        return INIT_FAILED;
    }
    
    Print("EMA9 EA initialized successfully");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // Release indicator handle
    if(ema_handle != INVALID_HANDLE)
        IndicatorRelease(ema_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check if we should trade only on new bar
    if(TradeOnNewBar)
    {
        datetime current_bar_time = iTime(_Symbol, PERIOD_M1, 0);
        if(current_bar_time == last_bar_time)
            return;
        last_bar_time = current_bar_time;
    }
    
    // Get current EMA value
    if(!GetCurrentEMA())
        return;
    
    // Get current price
    double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    // Check trading conditions
    CheckTradingConditions(current_price);
}

//+------------------------------------------------------------------+
//| Get current EMA value                                            |
//+------------------------------------------------------------------+
bool GetCurrentEMA()
{
    double ema_buffer[];
    ArraySetAsSeries(ema_buffer, true);
    
    if(CopyBuffer(ema_handle, 0, 0, 1, ema_buffer) <= 0)
    {
        Print("Error getting EMA data");
        return false;
    }
    
    current_ema = ema_buffer[0];
    return true;
}

//+------------------------------------------------------------------+
//| Check trading conditions                                         |
//+------------------------------------------------------------------+
void CheckTradingConditions(double current_price)
{
    // Check if we have any open positions
    if(HasOpenPosition())
    {
        // Update trailing stops for existing positions
        UpdateTrailingStops();
        return;
    }
    
    // Stop opening new trades if daily profit limit reached
    if(DailyProfitLimitPoints > 0)
    {
        double todayPoints = GetTodayNetProfitPoints();
        if(todayPoints >= DailyProfitLimitPoints)
            return;
    }
    
    // Buy condition: Price above EMA 9
    if(current_price > current_ema)
    {
        OpenBuyOrder(current_price);
    }
    // Sell condition: Price below EMA 9
    else if(current_price < current_ema)
    {
        OpenSellOrder(current_price);
    }
}

//+------------------------------------------------------------------+
//| Check if there are open positions                               |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Open buy order                                                   |
//+------------------------------------------------------------------+
void OpenBuyOrder(double current_price)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    // Set order parameters
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = LotSize;
    request.type = ORDER_TYPE_BUY;
    request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    // Initial SL at recent swing low + buffer
    double swingLow = GetRecentSwingLow(SwingLookbackBars);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double buffer = SwingSLBufferPoints * point;
    request.sl = swingLow > 0.0 ? swingLow + buffer : 0.0;
    // Fixed TP in points from entry price
    request.tp = request.price + (TakeProfitPoints * point);
    request.deviation = Slippage;
    request.magic = MagicNumber;
    request.comment = "EMA9 Buy";
    
    // Send order
    if(OrderSend(request, result))
    {
        if(result.retcode == TRADE_RETCODE_DONE)
        {
            Print("Buy order opened successfully. Ticket: ", result.order);
        }
        else
        {
            Print("Buy order failed. Error: ", result.retcode);
        }
    }
    else
    {
        Print("Error sending buy order: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Open sell order                                                  |
//+------------------------------------------------------------------+
void OpenSellOrder(double current_price)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    // Set order parameters
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = LotSize;
    request.type = ORDER_TYPE_SELL;
    request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    // Initial SL at recent swing high - buffer
    double swingHigh = GetRecentSwingHigh(SwingLookbackBars);
    double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double buffer = SwingSLBufferPoints * point;
    request.sl = swingHigh > 0.0 ? swingHigh - buffer : 0.0;
    // Fixed TP in points from entry price
    request.tp = request.price - (TakeProfitPoints * point);
    request.deviation = Slippage;
    request.magic = MagicNumber;
    request.comment = "EMA9 Sell";
    
    // Send order
    if(OrderSend(request, result))
    {
        if(result.retcode == TRADE_RETCODE_DONE)
        {
            Print("Sell order opened successfully. Ticket: ", result.order);
        }
        else
        {
            Print("Sell order failed. Error: ", result.retcode);
        }
    }
    else
    {
        Print("Error sending sell order: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Update trailing stops for open positions                        |
//+------------------------------------------------------------------+
void UpdateTrailingStops()
{
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
        {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double current_sl = PositionGetDouble(POSITION_SL);
            double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
            double current_price = PositionGetDouble(POSITION_PRICE_CURRENT);
            double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            long digits = (long)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
            double beTrigger = BreakevenTriggerPoints * point;
            double trailTrigger = TrailTriggerPoints * point;
            double beOffset = BreakevenOffsetPoints * point;
            
            MqlTradeRequest request = {};
            MqlTradeResult result = {};
            
            // Set basic parameters
            request.action = TRADE_ACTION_SLTP;
            request.symbol = _Symbol;
            request.position = ticket;
            request.magic = MagicNumber;
            
            if(pos_type == POSITION_TYPE_BUY)
            {
                double profitPoints = (current_price - open_price) / point;
                // 1) Move to BE+offset after threshold
                if(profitPoints >= BreakevenTriggerPoints)
                {
                    double bePrice = open_price + beOffset; // +offset for buy
                    // Only raise SL, never lower
                    if(current_sl < bePrice - point)
                    {
                        request.sl = bePrice;
                        request.tp = 0;
                        if(OrderSend(request, result))
                        {
                            if(result.retcode == TRADE_RETCODE_DONE)
                                Print("BUY ", ticket, ": SL moved to BE+offset ", DoubleToString(bePrice, (int)digits));
                        }
                    }
                }
                // 2) Start EMA trailing only after larger profit threshold
                if(profitPoints >= TrailTriggerPoints)
                {
                    if(current_ema < current_price)
                    {
                        if(MathAbs(current_sl - current_ema) > point)
                        {
                            // Only raise SL for buy
                            if(current_ema > current_sl + point)
                            {
                                request.sl = current_ema;
                                request.tp = 0;
                                if(OrderSend(request, result))
                                {
                                    if(result.retcode == TRADE_RETCODE_DONE)
                                        Print("BUY ", ticket, ": EMA9 trail to ", DoubleToString(current_ema, (int)digits));
                                }
                            }
                        }
                    }
                }
            }
            else if(pos_type == POSITION_TYPE_SELL)
            {
                double profitPoints = (open_price - current_price) / point;
                // 1) Move to BE-offset after threshold
                if(profitPoints >= BreakevenTriggerPoints)
                {
                    double bePrice = open_price - beOffset; // -offset for sell (beOffset may be positive)
                    // Only lower SL for sell (improve)
                    if(current_sl == 0.0 || current_sl > bePrice + point)
                    {
                        request.sl = bePrice;
                        request.tp = 0;
                        if(OrderSend(request, result))
                        {
                            if(result.retcode == TRADE_RETCODE_DONE)
                                Print("SELL ", ticket, ": SL moved to BE-offset ", DoubleToString(bePrice, (int)digits));
                        }
                    }
                }
                // 2) Start EMA trailing only after larger profit threshold
                if(profitPoints >= TrailTriggerPoints)
                {
                    if(current_ema > current_price)
                    {
                        if(MathAbs(current_sl - current_ema) > point)
                        {
                            // Only lower SL for sell
                            if(current_ema < current_sl - point || current_sl == 0.0)
                            {
                                request.sl = current_ema;
                                request.tp = 0;
                                if(OrderSend(request, result))
                                {
                                    if(result.retcode == TRADE_RETCODE_DONE)
                                        Print("SELL ", ticket, ": EMA9 trail to ", DoubleToString(current_ema, (int)digits));
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
