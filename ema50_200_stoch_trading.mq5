//+------------------------------------------------------------------+
//|                                    ema50_200_stoch_trading.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

//--- Input parameters
input double LotSize = 0.01;                    // Lot size
input int EMA_Period_50 = 50;                   // EMA 50 period
input int EMA_Period_200 = 200;                 // EMA 200 period
input int Stoch_K_Period = 9;                   // Stochastic %K period
input int Stoch_D_Period = 3;                   // Stochastic %D period
input int Stoch_Slowing = 3;                    // Stochastic slowing
input int TP_Points = 2000;                     // Take Profit in points
input int SL_Points_Buy = 1000;                // Stop Loss for Buy orders in points
input int SL_Points_Sell = 1000;               // Stop Loss for Sell orders in points
input int Max_Profit_Per_Day = 3000;            // Maximum profit per day in points
input int Start_Hour = 5;                       // Trading start hour (Bangkok time)
input int End_Hour = 23;                        // Trading end hour (Bangkok time)

//--- Global variables
int ema50_handle, ema200_handle, stoch_handle;
double ema50_buffer[], ema200_buffer[];
double stoch_main_buffer[], stoch_signal_buffer[];
datetime last_trade_date = 0;
double daily_profit = 0.0;
bool trading_allowed_today = true;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Create indicator handles
    ema50_handle = iMA(_Symbol, PERIOD_M1, EMA_Period_50, 0, MODE_EMA, PRICE_CLOSE);
    ema200_handle = iMA(_Symbol, PERIOD_M1, EMA_Period_200, 0, MODE_EMA, PRICE_CLOSE);
    stoch_handle = iStochastic(_Symbol, PERIOD_M1, Stoch_K_Period, Stoch_D_Period, Stoch_Slowing, MODE_SMA, STO_LOWHIGH);
    
    if(ema50_handle == INVALID_HANDLE || ema200_handle == INVALID_HANDLE || stoch_handle == INVALID_HANDLE)
    {
        Print("Error creating indicator handles");
        return INIT_FAILED;
    }
    
    //--- Set array as series
    ArraySetAsSeries(ema50_buffer, true);
    ArraySetAsSeries(ema200_buffer, true);
    ArraySetAsSeries(stoch_main_buffer, true);
    ArraySetAsSeries(stoch_signal_buffer, true);
    
    Print("EA initialized successfully");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- Release indicator handles
    if(ema50_handle != INVALID_HANDLE) IndicatorRelease(ema50_handle);
    if(ema200_handle != INVALID_HANDLE) IndicatorRelease(ema200_handle);
    if(stoch_handle != INVALID_HANDLE) IndicatorRelease(stoch_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Check if new day started
    CheckNewDay();
    
    //--- Check if trading is allowed today
    if(!trading_allowed_today)
        return;
    
    //--- Check if daily profit limit reached
    if(daily_profit >= Max_Profit_Per_Day * _Point * LotSize * 100000)
    {
        trading_allowed_today = false;
        Print("Daily profit limit reached: ", daily_profit);
        return;
    }
    
    //--- Check trading time (Bangkok timezone)
    if(!IsWithinTradingHours())
        return;
    
    //--- Get indicator values
    if(!GetIndicatorValues())
        return;
    
    //--- Check for trading signals
    CheckTradingSignals();
    
    //--- Manage existing positions
    ManagePositions();
}

//+------------------------------------------------------------------+
//| Check if new day started                                         |
//+------------------------------------------------------------------+
void CheckNewDay()
{
    datetime current_time = TimeCurrent();
    datetime bangkok_time = TimeToBangkok(current_time);
    MqlDateTime dt;
    TimeToStruct(bangkok_time, dt);
    
    datetime current_date = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
    
    if(current_date != last_trade_date)
    {
        last_trade_date = current_date;
        daily_profit = 0.0;
        trading_allowed_today = true;
        Print("New trading day started: ", TimeToString(bangkok_time, TIME_DATE));
    }
}

//+------------------------------------------------------------------+
//| Convert time to Bangkok timezone                                 |
//+------------------------------------------------------------------+
datetime TimeToBangkok(datetime utc_time)
{
    return utc_time + 7 * 3600; // Bangkok is UTC+7
}

//+------------------------------------------------------------------+
//| Check if current time is within trading hours                    |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
    datetime current_time = TimeCurrent();
    datetime bangkok_time = TimeToBangkok(current_time);
    MqlDateTime dt;
    TimeToStruct(bangkok_time, dt);
    
    return (dt.hour >= Start_Hour && dt.hour < End_Hour);
}

//+------------------------------------------------------------------+
//| Get indicator values                                             |
//+------------------------------------------------------------------+
bool GetIndicatorValues()
{
    //--- Copy EMA values
    if(CopyBuffer(ema50_handle, 0, 0, 3, ema50_buffer) < 3)
        return false;
    if(CopyBuffer(ema200_handle, 0, 0, 3, ema200_buffer) < 3)
        return false;
    
    //--- Copy Stochastic values
    if(CopyBuffer(stoch_handle, 0, 0, 3, stoch_main_buffer) < 3)
        return false;
    if(CopyBuffer(stoch_handle, 1, 0, 3, stoch_signal_buffer) < 3)
        return false;
    
    return true;
}

//+------------------------------------------------------------------+
//| Check for trading signals                                        |
//+------------------------------------------------------------------+
void CheckTradingSignals()
{
    //--- Don't trade if we already have a position
    if(PositionsTotal() > 0)
        return;
    
    double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ema50_current = ema50_buffer[0];
    double ema200_current = ema200_buffer[0];
    double stoch_current = stoch_main_buffer[0];
    double stoch_previous = stoch_main_buffer[1];
    
    //--- Buy conditions
    if(ema50_current > ema200_current)
    {
        // Check if Stochastic touched 20 from above
        if(stoch_previous > 20 && stoch_current <= 20)
        {
            OpenBuyOrder();
        }
    }
    
    //--- Sell conditions
    if(ema50_current < ema200_current)
    {
        // Check if Stochastic touched 80 from below
        if(stoch_previous < 80 && stoch_current >= 80)
        {
            OpenSellOrder();
        }
    }
}

//+------------------------------------------------------------------+
//| Open Buy order                                                   |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl = ask - SL_Points_Buy * _Point;
    double tp = ask + TP_Points * _Point;
    
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = LotSize;
    request.type = ORDER_TYPE_BUY;
    request.price = ask;
    request.sl = sl;
    request.tp = tp;
    request.deviation = 10;
    request.magic = 12345;
    request.comment = "EMA50_200_Stoch_Buy";
    
    if(OrderSend(request, result))
    {
        Print("Buy order opened successfully. Ticket: ", result.order);
    }
    else
    {
        Print("Error opening buy order: ", result.retcode);
    }
}

//+------------------------------------------------------------------+
//| Open Sell order                                                  |
//+------------------------------------------------------------------+
void OpenSellOrder()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = bid + SL_Points_Sell * _Point;
    double tp = bid - TP_Points * _Point;
    
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = LotSize;
    request.type = ORDER_TYPE_SELL;
    request.price = bid;
    request.sl = sl;
    request.tp = tp;
    request.deviation = 10;
    request.magic = 12345;
    request.comment = "EMA50_200_Stoch_Sell";
    
    if(OrderSend(request, result))
    {
        Print("Sell order opened successfully. Ticket: ", result.order);
    }
    else
    {
        Print("Error opening sell order: ", result.retcode);
    }
}


//+------------------------------------------------------------------+
//| Manage existing positions                                         |
//+------------------------------------------------------------------+
void ManagePositions()
{
    // No trailing stop management needed
}

//+------------------------------------------------------------------+
//| Modify position                                                   |
//+------------------------------------------------------------------+
void ModifyPosition(ulong ticket, double sl, double tp)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_SLTP;
    request.position = ticket;
    request.sl = sl;
    request.tp = tp;
    
    if(OrderSend(request, result))
    {
        Print("Position modified successfully. New SL: ", sl);
    }
    else
    {
        Print("Error modifying position: ", result.retcode);
    }
}

//+------------------------------------------------------------------+
//| Trade transaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                       const MqlTradeRequest& request,
                       const MqlTradeResult& result)
{
    //--- Check if position was closed
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        if(HistoryDealSelect(trans.deal))
        {
            double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            ENUM_DEAL_ENTRY deal_entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
            
            if(deal_entry == DEAL_ENTRY_OUT)
            {
                daily_profit += profit;
                Print("Position closed. Profit: ", profit, " Daily total: ", daily_profit);
                
                if(daily_profit >= Max_Profit_Per_Day * _Point * LotSize * 100000)
                {
                    trading_allowed_today = false;
                    Print("Trading stopped for today due to profit limit reached");
                }
            }
        }
    }
}
