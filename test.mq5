//+------------------------------------------------------------------+
//| EMA9/EMA50 Crossover Strategy                                     |
//| BUY: EMA9 crosses above EMA50, SL at swing low (50 bars), TP 500|
//| SELL: EMA9 crosses below EMA50, SL at swing high (50 bars), TP 500|
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

// Input parameters
input double Lots = 0.10;           // Lot size
input int TP_Points = 500;          // Take Profit in points
input int EMA_Fast = 9;             // Fast EMA period
input int EMA_Slow = 50;            // Slow EMA period
input ulong Magic = 123456;         // Magic number

// Global variables
CTrade trade;
int hEMA_Fast, hEMA_Slow;
datetime lastBarTime = 0;
bool newBar = false;

// Variables for swing levels
double lastLow = 0;                // Last low for BUY SL
double lastHigh = 0;               // Last high for SELL SL

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Set magic number for trade identification
    trade.SetExpertMagicNumber(Magic);
    
    // Create EMA handles
    hEMA_Fast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    hEMA_Slow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
    
    if(hEMA_Fast == INVALID_HANDLE || hEMA_Slow == INVALID_HANDLE)
    {
        Print("Error: Failed to create EMA indicators");
        return INIT_FAILED;
    }
    
    Print("EMA Crossover Strategy EA initialized successfully");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(hEMA_Fast != INVALID_HANDLE) IndicatorRelease(hEMA_Fast);
    if(hEMA_Slow != INVALID_HANDLE) IndicatorRelease(hEMA_Slow);
    Print("EA deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check for new bar
    datetime currentBarTime = (datetime)SeriesInfoInteger(_Symbol, PERIOD_CURRENT, SERIES_LASTBAR_DATE);
    if(currentBarTime != lastBarTime)
    {
        newBar = true;
        lastBarTime = currentBarTime;
    }
    else
    {
        newBar = false;
    }
    
    // Don't open new positions if we already have one
    if(PositionSelect(_Symbol)) return;
    
    // Get current prices
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double point = _Point;
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    
    // Get EMA values for current and previous bars
    double emaFast[2], emaSlow[2];
    
    if(CopyBuffer(hEMA_Fast, 0, 1, 2, emaFast) != 2) return;
    if(CopyBuffer(hEMA_Slow, 0, 1, 2, emaSlow) != 2) return;
    
    // Get recent low and high for SL calculation
    if(newBar)
    {
        // Find last low (for BUY SL) - look at last 50 bars
        double lowBuffer[50];
        if(CopyLow(_Symbol, PERIOD_CURRENT, 1, 50, lowBuffer) == 50)
        {
            lastLow = lowBuffer[ArrayMinimum(lowBuffer)];
        }
        
        // Find last high (for SELL SL) - look at last 50 bars
        double highBuffer[50];
        if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, 50, highBuffer) == 50)
        {
            lastHigh = highBuffer[ArrayMaximum(highBuffer)];
        }
    }
    
    // BUY Signal: EMA9 crosses ABOVE EMA50 (Bullish Crossover)
    if(emaFast[1] <= emaSlow[1] && emaFast[0] > emaSlow[0])
    {
        Print("🟢 Bullish crossover detected - Opening BUY order");
        
        // Calculate SL and TP
        double entryPrice = ask;
        double stopLoss = NormalizeDouble(lastLow - 5 * point, digits);
        double takeProfit = NormalizeDouble(entryPrice + TP_Points * point, digits);
        
        // Check broker stop level
        long stopLevel = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
        double minDistance = stopLevel * point;
        
        if((entryPrice - stopLoss) < minDistance)
            stopLoss = NormalizeDouble(entryPrice - minDistance - 10 * point, digits);
        if((takeProfit - entryPrice) < minDistance)
            takeProfit = NormalizeDouble(entryPrice + minDistance + 10 * point, digits);
        
        if(trade.Buy(Lots, _Symbol, entryPrice, stopLoss, takeProfit, "EMA9>EMA50 Crossover"))
        {
            Print("✅ BUY order opened: Entry=", entryPrice, " SL=", stopLoss, " TP=", takeProfit);
        }
        else
        {
            Print("❌ BUY order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
        }
    }
    
    // SELL Signal: EMA9 crosses BELOW EMA50 (Bearish Crossover)
    if(emaFast[1] >= emaSlow[1] && emaFast[0] < emaSlow[0])
    {
        Print("🔴 Bearish crossover detected - Opening SELL order");
        
        // Calculate SL and TP
        double entryPrice = bid;
        double stopLoss = NormalizeDouble(lastHigh + 5 * point, digits);
        double takeProfit = NormalizeDouble(entryPrice - TP_Points * point, digits);
        
        // Check broker stop level
        long stopLevel = (long)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
        double minDistance = stopLevel * point;
        
        if((stopLoss - entryPrice) < minDistance)
            stopLoss = NormalizeDouble(entryPrice + minDistance + 10 * point, digits);
        if((entryPrice - takeProfit) < minDistance)
            takeProfit = NormalizeDouble(entryPrice - minDistance - 10 * point, digits);
        
        if(trade.Sell(Lots, _Symbol, entryPrice, stopLoss, takeProfit, "EMA9<EMA50 Crossover"))
        {
            Print("✅ SELL order opened: Entry=", entryPrice, " SL=", stopLoss, " TP=", takeProfit);
        }
        else
        {
            Print("❌ SELL order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
        }
    }
}
