//+------------------------------------------------------------------+
//|                                    ema14-26-50-100-200-sto.mq5 |
//|                        Copyright 2024, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== EMA Settings ==="
input int    EMA14_Period = 14;      // EMA 14 Period
input int    EMA26_Period = 26;      // EMA 26 Period  
input int    EMA50_Period = 50;      // EMA 50 Period
input int    EMA100_Period = 100;    // EMA 100 Period
input int    EMA200_Period = 200;    // EMA 200 Period

input group "=== Trading Settings ==="
input double LotSize = 0.1;          // Lot Size
input int    LimitDistance = 200;    // Buy/Sell Limit Distance (points)
input int    TakeProfit = 1000;      // Take Profit (points)
input int    BreakevenProfit = 500;  // Profit to move SL to breakeven (points)
input int    BreakevenBuffer = 20;   // Breakeven SL buffer (points)

input group "=== Time Settings ==="
input int    StartHour = 5;          // Trading start hour (Bangkok time)
input int    EndHour = 23;           // Trading end hour (Bangkok time)

//--- Global variables
CTrade trade;
int ema14_handle, ema26_handle, ema50_handle, ema100_handle, ema200_handle;
datetime lastBarTime = 0;
datetime lastDay = 0;
bool hasPosition = false;
double entryPrice = 0;
double swingHigh = 0;
double swingLow = 0;
bool buySignalTriggered = false;
bool sellSignalTriggered = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Initialize EMA handles
    ema14_handle = iMA(_Symbol, PERIOD_M5, EMA14_Period, 0, MODE_EMA, PRICE_CLOSE);
    ema26_handle = iMA(_Symbol, PERIOD_M5, EMA26_Period, 0, MODE_EMA, PRICE_CLOSE);
    ema50_handle = iMA(_Symbol, PERIOD_M5, EMA50_Period, 0, MODE_EMA, PRICE_CLOSE);
    ema100_handle = iMA(_Symbol, PERIOD_M5, EMA100_Period, 0, MODE_EMA, PRICE_CLOSE);
    ema200_handle = iMA(_Symbol, PERIOD_M5, EMA200_Period, 0, MODE_EMA, PRICE_CLOSE);
    
    if(ema14_handle == INVALID_HANDLE || ema26_handle == INVALID_HANDLE || 
       ema50_handle == INVALID_HANDLE || ema100_handle == INVALID_HANDLE || 
       ema200_handle == INVALID_HANDLE)
    {
        Print("Error creating EMA handles");
        return INIT_FAILED;
    }
    
    // Initialize trade object
    trade.SetExpertMagicNumber(123456);
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(ema14_handle != INVALID_HANDLE) IndicatorRelease(ema14_handle);
    if(ema26_handle != INVALID_HANDLE) IndicatorRelease(ema26_handle);
    if(ema50_handle != INVALID_HANDLE) IndicatorRelease(ema50_handle);
    if(ema100_handle != INVALID_HANDLE) IndicatorRelease(ema100_handle);
    if(ema200_handle != INVALID_HANDLE) IndicatorRelease(ema200_handle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check for new bar
    if(!IsNewBar()) return;
    
    // Reset daily SL count at new day
    CheckNewDay();
    
    // Check if trading time
    if(!IsTradingTime()) return;
    
    
    // Find swing levels
    FindSwingLevels();
    
    // Manage existing positions
    if(PositionsTotal() > 0) 
    {
        ManagePositions();
    }
    
    // Check for trading opportunities
    CheckBuyConditions();
    CheckSellConditions();
}

//+------------------------------------------------------------------+
//| Check if new bar formed                                          |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_M5, 0);
    if(currentBarTime != lastBarTime)
    {
        lastBarTime = currentBarTime;
        return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Check if it's trading time (Bangkok timezone)                   |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
    datetime bangkokTime = TimeGMT() + 7 * 3600; // Bangkok is GMT+7
    MqlDateTime dt;
    TimeToStruct(bangkokTime, dt);
    
    return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
//| Check for new day and reset daily counters                      |
//+------------------------------------------------------------------+
void CheckNewDay()
{
    datetime bangkokTime = TimeGMT() + 7 * 3600;
    MqlDateTime dt;
    TimeToStruct(bangkokTime, dt);
    datetime currentDay = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
    
    if(currentDay != lastDay)
    {
        lastDay = currentDay;
        buySignalTriggered = false;
        sellSignalTriggered = false;
        Print("New day started, signal triggers reset");
    }
}

//+------------------------------------------------------------------+
//| Find swing high and swing low                                   |
//+------------------------------------------------------------------+
void FindSwingLevels()
{
    double high[], low[];
    ArraySetAsSeries(high, true);
    ArraySetAsSeries(low, true);
    
    if(CopyHigh(_Symbol, PERIOD_M5, 1, 50, high) <= 0) return;
    if(CopyLow(_Symbol, PERIOD_M5, 1, 50, low) <= 0) return;
    
    // Find swing high (highest high in last 10 bars)
    int swingHighIndex = ArrayMaximum(high, 0, 10);
    if(swingHighIndex >= 0)
        swingHigh = high[swingHighIndex];
    
    // Find swing low (lowest low in last 10 bars)
    int swingLowIndex = ArrayMinimum(low, 0, 10);
    if(swingLowIndex >= 0)
        swingLow = low[swingLowIndex];
}

//+------------------------------------------------------------------+
//| Check Buy conditions                                             |
//+------------------------------------------------------------------+
void CheckBuyConditions()
{
    // Skip if signal already triggered today
    if(buySignalTriggered) return;
    
    double ema14[], ema26[], ema50[], ema100[], ema200[];
    ArraySetAsSeries(ema14, true);
    ArraySetAsSeries(ema26, true);
    ArraySetAsSeries(ema50, true);
    ArraySetAsSeries(ema100, true);
    ArraySetAsSeries(ema200, true);
    
    if(CopyBuffer(ema14_handle, 0, 0, 3, ema14) <= 0) return;
    if(CopyBuffer(ema26_handle, 0, 0, 3, ema26) <= 0) return;
    if(CopyBuffer(ema50_handle, 0, 0, 3, ema50) <= 0) return;
    if(CopyBuffer(ema100_handle, 0, 0, 3, ema100) <= 0) return;
    if(CopyBuffer(ema200_handle, 0, 0, 3, ema200) <= 0) return;
    
    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    
    // Check EMA stacking: ema14 > ema26 > ema50 > ema100 > ema200
    bool emaStacking = (ema14[0] > ema26[0] && ema26[0] > ema50[0] && 
                       ema50[0] > ema100[0] && ema100[0] > ema200[0]);
    
    // Check if price is above all EMAs
    bool priceAboveEMAs = (currentPrice > ema14[0]);
    
    if(emaStacking && priceAboveEMAs)
    {
        // 1. Place immediate Buy order
        double sl = swingLow;
        double tp = currentPrice + TakeProfit * _Point;
        
        if(trade.Buy(LotSize, _Symbol, currentPrice, sl, tp, "EMA Buy Immediate"))
        {
            Print("Immediate Buy order placed at ", currentPrice, " SL: ", sl, " TP: ", tp);
            entryPrice = currentPrice;
            
            // 2. Place Buy Limit order 200 points away
            double buyLimitPrice = currentPrice - LimitDistance * _Point;
            
            // Ensure buy limit doesn't go below swing low
            if(buyLimitPrice > swingLow && swingLow > 0)
            {
                double limitSL = swingLow;
                double limitTP = buyLimitPrice + TakeProfit * _Point;
                
                if(trade.BuyLimit(LotSize, buyLimitPrice, _Symbol, limitSL, limitTP, ORDER_TIME_DAY, 0, "EMA Buy Limit"))
                {
                    Print("Buy Limit order placed at ", buyLimitPrice, " SL: ", limitSL, " TP: ", limitTP);
                }
            }
            
            buySignalTriggered = true;
            hasPosition = true;
        }
    }
}

//+------------------------------------------------------------------+
//| Check Sell conditions                                            |
//+------------------------------------------------------------------+
void CheckSellConditions()
{
    // Skip if signal already triggered today
    if(sellSignalTriggered) return;
    
    double ema14[], ema26[], ema50[], ema100[], ema200[];
    ArraySetAsSeries(ema14, true);
    ArraySetAsSeries(ema26, true);
    ArraySetAsSeries(ema50, true);
    ArraySetAsSeries(ema100, true);
    ArraySetAsSeries(ema200, true);
    
    if(CopyBuffer(ema14_handle, 0, 0, 3, ema14) <= 0) return;
    if(CopyBuffer(ema26_handle, 0, 0, 3, ema26) <= 0) return;
    if(CopyBuffer(ema50_handle, 0, 0, 3, ema50) <= 0) return;
    if(CopyBuffer(ema100_handle, 0, 0, 3, ema100) <= 0) return;
    if(CopyBuffer(ema200_handle, 0, 0, 3, ema200) <= 0) return;
    
    double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    // Check EMA stacking: ema14 < ema26 < ema50 < ema100 < ema200
    bool emaStacking = (ema14[0] < ema26[0] && ema26[0] < ema50[0] && 
                       ema50[0] < ema100[0] && ema100[0] < ema200[0]);
    
    // Check if price is below all EMAs
    bool priceBelowEMAs = (currentPrice < ema14[0]);
    
    if(emaStacking && priceBelowEMAs)
    {
        // 1. Place immediate Sell order
        double sl = swingHigh;
        double tp = currentPrice - TakeProfit * _Point;
        
        if(trade.Sell(LotSize, _Symbol, currentPrice, sl, tp, "EMA Sell Immediate"))
        {
            Print("Immediate Sell order placed at ", currentPrice, " SL: ", sl, " TP: ", tp);
            entryPrice = currentPrice;
            
            // 2. Place Sell Limit order 200 points away (but not beyond SL level)
            double sellLimitPrice = currentPrice + LimitDistance * _Point;
            
            // Ensure sell limit doesn't go above swing high (SL level)
            if(sellLimitPrice < swingHigh && swingHigh > 0)
            {
                double limitSL = swingHigh;
                double limitTP = sellLimitPrice - TakeProfit * _Point;
                
                if(trade.SellLimit(LotSize, sellLimitPrice, _Symbol, limitSL, limitTP, ORDER_TIME_DAY, 0, "EMA Sell Limit"))
                {
                    Print("Sell Limit order placed at ", sellLimitPrice, " SL: ", limitSL, " TP: ", limitTP);
                }
            }
            
            sellSignalTriggered = true;
            hasPosition = true;
        }
    }
}

//+------------------------------------------------------------------+
//| Manage open positions                                            |
//+------------------------------------------------------------------+
void ManagePositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetSymbol(i) != _Symbol) continue;
        
        ulong ticket = PositionGetInteger(POSITION_TICKET);
        double profit = PositionGetDouble(POSITION_PROFIT);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL = PositionGetDouble(POSITION_SL);
        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        
        // Check if position has profit >= 500 points
        if(MathAbs(profit) >= BreakevenProfit * _Point * LotSize * 100000)
        {
            double newSL;
            if(type == POSITION_TYPE_BUY)
            {
                newSL = openPrice + BreakevenBuffer * _Point;
                if(newSL > currentSL || currentSL == 0)
                {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                    Print("Buy position moved to breakeven + buffer. New SL: ", newSL);
                }
            }
            else if(type == POSITION_TYPE_SELL)
            {
                newSL = openPrice - BreakevenBuffer * _Point;
                if(newSL < currentSL || currentSL == 0)
                {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                    Print("Sell position moved to breakeven - buffer. New SL: ", newSL);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Trade transaction function                                       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    // Check if position was closed by stop loss
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        if(HistoryDealSelect(trans.deal))
        {
            long reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
            if(reason == DEAL_REASON_SL)
            {
                double dealPrice = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
                
                // Check if SL hit was at swing level (within 10 points)
                if(MathAbs(dealPrice - swingHigh) <= 10 * _Point || 
                   MathAbs(dealPrice - swingLow) <= 10 * _Point)
                {
                    Print("SL hit at swing level at price: ", dealPrice);
                }
                else
                {
                    Print("SL hit at breakeven level at price: ", dealPrice);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
 