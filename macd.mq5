//+------------------------------------------------------------------+
//|                                                    MACD_Grid_EA.mq5 |
//|                                  Copyright 2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "MACD Divergence Grid Trading EA"

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== TRADING SETTINGS ==="
input double   Lots = 0.10;                    // Lot size
input int      MagicNumber = 123456;           // Magic number for this EA
input bool     EnableBuy = true;               // Enable Buy trading
input bool     EnableSell = true;              // Enable Sell trading
input string   TradeSymbol = "";               // Trading symbol (empty = current chart)
input bool     AllowNewSequence = true;        // Allow new sequences

input group "=== GRID SETTINGS ==="
input int      PendingCount = 9;               // Number of pending orders
input int      PendingStepPoints = 500;        // Step between pending orders (points)
input int      TP1PointsWhen2Active = 1000;    // TP when 2 orders active (points)
input bool     UseAverageTP = false;           // Use average price for TP

input group "=== DIVERGENCE SETTINGS ==="
input int      DivergenceLookbackBars = 100;   // Lookback for divergence detection
input int      MinSwingGapBars = 5;            // Minimum gap between swing points
input int      MACD_FastEMA = 12;              // MACD Fast EMA
input int      MACD_SlowEMA = 26;              // MACD Slow EMA
input int      MACD_SignalSMA = 9;             // MACD Signal SMA

input group "=== RISK MANAGEMENT ==="
input int      MaxSpreadPoints = 30;           // Maximum spread (points)
input int      SlippagePoints = 5;             // Slippage tolerance (points)

//--- Global variables
CTrade trade;
int macd_handle;
double macd_main[], macd_signal[];

//--- State management
enum EA_STATE {
    IDLE,
    BUY_SEQUENCE_ACTIVE,
    SELL_SEQUENCE_ACTIVE
};

EA_STATE current_state = IDLE;
datetime last_divergence_time = 0;
int cooldown_bars = 5;

//--- Order tracking
struct OrderInfo {
    ulong ticket;
    double price;
    bool is_market;
    datetime time;
};

OrderInfo buy_orders[10];  // Market + 9 pending
OrderInfo sell_orders[10]; // Market + 9 pending
int buy_order_count = 0;
int sell_order_count = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Check timeframe
    if(Period() != PERIOD_M1) {
        Comment("ERROR: This EA only works on M1 timeframe!");
        return INIT_FAILED;
    }
    
    // Validate inputs
    if(Lots <= 0 || PendingCount <= 0 || PendingStepPoints <= 0) {
        Comment("ERROR: Invalid input parameters!");
        return INIT_FAILED;
    }
    
    // Initialize MACD indicator
    macd_handle = iMACD(TradeSymbol == "" ? _Symbol : TradeSymbol, 
                       PERIOD_M1, MACD_FastEMA, MACD_SlowEMA, MACD_SignalSMA, PRICE_CLOSE);
    
    if(macd_handle == INVALID_HANDLE) {
        Comment("ERROR: Failed to create MACD indicator!");
        return INIT_FAILED;
    }
    
    // Set trade parameters
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(SlippagePoints);
    
    // Initialize arrays
    ArraySetAsSeries(macd_main, true);
    ArraySetAsSeries(macd_signal, true);
    
    // Reset order tracking
    ResetOrderTracking();
    
    // Recover state from existing positions
    RecoverState();
    
    Comment("MACD Grid EA initialized successfully");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(macd_handle != INVALID_HANDLE)
        IndicatorRelease(macd_handle);
        
    Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check if trading is allowed
    if(!IsTradeAllowed()) return;
    
    // Update MACD data
    if(!UpdateMACDData()) return;
    
    // Check spread
    if(!CheckSpread()) return;
    
    // Main logic
    if(current_state == IDLE && AllowNewSequence) {
        CheckForDivergence();
    }
    
    if(current_state == BUY_SEQUENCE_ACTIVE) {
        ManageBuySequence();
    }
    
    if(current_state == SELL_SEQUENCE_ACTIVE) {
        ManageSellSequence();
    }
    
    // Update display
    UpdateDisplay();
}

//+------------------------------------------------------------------+
//| Update MACD data                                                 |
//+------------------------------------------------------------------+
bool UpdateMACDData()
{
    if(CopyBuffer(macd_handle, 0, 0, DivergenceLookbackBars + 10, macd_main) <= 0) {
        Print("Error copying MACD main buffer");
        return false;
    }
    
    if(CopyBuffer(macd_handle, 1, 0, DivergenceLookbackBars + 10, macd_signal) <= 0) {
        Print("Error copying MACD signal buffer");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Check if trading is allowed                                      |
//+------------------------------------------------------------------+
bool IsTradeAllowed()
{
    if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {
        Comment("Trading not allowed by terminal");
        return false;
    }
    
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) {
        Comment("Trading not allowed by EA");
        return false;
    }
    
    if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) {
        Comment("Trading not allowed on account");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Check spread                                                     |
//+------------------------------------------------------------------+
bool CheckSpread()
{
    int spread = (int)SymbolInfoInteger(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_SPREAD);
    if(spread > MaxSpreadPoints) {
        Comment("Spread too high: ", spread, " points (max: ", MaxSpreadPoints, ")");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Check for divergence patterns                                    |
//+------------------------------------------------------------------+
void CheckForDivergence()
{
    // Cooldown check
    if(last_divergence_time > 0 && 
       TimeCurrent() - last_divergence_time < cooldown_bars * 60) {
        return;
    }
    
    // Check bullish divergence
    if(EnableBuy && DetectDivergence(true)) {
        StartSequence(true);
        return;
    }
    
    // Check bearish divergence
    if(EnableSell && DetectDivergence(false)) {
        StartSequence(false);
        return;
    }
}

//+------------------------------------------------------------------+
//| Detect divergence pattern                                        |
//+------------------------------------------------------------------+
bool DetectDivergence(bool bullish)
{
    int swing1_bar = -1, swing2_bar = -1;
    
    if(bullish) {
        // Find two recent swing lows
        if(!FindSwingLows(swing1_bar, swing2_bar)) return false;
        
        // Check divergence: price Low2 < Low1 while MACD Low2 > MACD Low1
        double price_low1 = iLow(TradeSymbol == "" ? _Symbol : TradeSymbol, PERIOD_M1, swing1_bar);
        double price_low2 = iLow(TradeSymbol == "" ? _Symbol : TradeSymbol, PERIOD_M1, swing2_bar);
        double macd_low1 = macd_main[swing1_bar];
        double macd_low2 = macd_main[swing2_bar];
        
        if(price_low2 < price_low1 && macd_low2 > macd_low1) {
            Print("Bullish divergence detected: Price ", price_low2, "<", price_low1, 
                  " MACD ", macd_low2, ">", macd_low1);
            return true;
        }
    } else {
        // Find two recent swing highs
        if(!FindSwingHighs(swing1_bar, swing2_bar)) return false;
        
        // Check divergence: price High2 > High1 while MACD High2 < MACD High1
        double price_high1 = iHigh(TradeSymbol == "" ? _Symbol : TradeSymbol, PERIOD_M1, swing1_bar);
        double price_high2 = iHigh(TradeSymbol == "" ? _Symbol : TradeSymbol, PERIOD_M1, swing2_bar);
        double macd_high1 = macd_main[swing1_bar];
        double macd_high2 = macd_main[swing2_bar];
        
        if(price_high2 > price_high1 && macd_high2 < macd_high1) {
            Print("Bearish divergence detected: Price ", price_high2, ">", price_high1, 
                  " MACD ", macd_high2, "<", macd_high1);
            return true;
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Find swing lows                                                  |
//+------------------------------------------------------------------+
bool FindSwingLows(int &swing1_bar, int &swing2_bar)
{
    int min_bars = MinSwingGapBars;
    
    // Look for two consecutive swing lows
    for(int i = min_bars; i < DivergenceLookbackBars - min_bars; i++) {
        double current_low = iLow(TradeSymbol == "" ? _Symbol : TradeSymbol, PERIOD_M1, i);
        
        // Check if this is a swing low
        bool is_swing_low = true;
        for(int j = 1; j <= min_bars; j++) {
            if(iLow(TradeSymbol == "" ? _Symbol : TradeSymbol, PERIOD_M1, i - j) <= current_low ||
               iLow(TradeSymbol == "" ? _Symbol : TradeSymbol, PERIOD_M1, i + j) <= current_low) {
                is_swing_low = false;
                break;
            }
        }
        
        if(is_swing_low) {
            if(swing1_bar == -1) {
                swing1_bar = i;
            } else if(swing2_bar == -1 && MathAbs(i - swing1_bar) >= min_bars) {
                swing2_bar = i;
                return true;
            }
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Find swing highs                                                 |
//+------------------------------------------------------------------+
bool FindSwingHighs(int &swing1_bar, int &swing2_bar)
{
    int min_bars = MinSwingGapBars;
    
    // Look for two consecutive swing highs
    for(int i = min_bars; i < DivergenceLookbackBars - min_bars; i++) {
        double current_high = iHigh(TradeSymbol == "" ? _Symbol : TradeSymbol, PERIOD_M1, i);
        
        // Check if this is a swing high
        bool is_swing_high = true;
        for(int j = 1; j <= min_bars; j++) {
            if(iHigh(TradeSymbol == "" ? _Symbol : TradeSymbol, PERIOD_M1, i - j) >= current_high ||
               iHigh(TradeSymbol == "" ? _Symbol : TradeSymbol, PERIOD_M1, i + j) >= current_high) {
                is_swing_high = false;
                break;
            }
        }
        
        if(is_swing_high) {
            if(swing1_bar == -1) {
                swing1_bar = i;
            } else if(swing2_bar == -1 && MathAbs(i - swing1_bar) >= min_bars) {
                swing2_bar = i;
                return true;
            }
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Start trading sequence                                           |
//+------------------------------------------------------------------+
void StartSequence(bool bullish)
{
    if(bullish) {
        current_state = BUY_SEQUENCE_ACTIVE;
        last_divergence_time = TimeCurrent();
        
        // Place market buy order
        double ask = SymbolInfoDouble(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_ASK);
        if(trade.Buy(Lots, TradeSymbol == "" ? _Symbol : TradeSymbol, ask, 0, 0, "MACD Grid Buy")) {
            buy_orders[0].ticket = trade.ResultOrder();
            buy_orders[0].price = ask;
            buy_orders[0].is_market = true;
            buy_orders[0].time = TimeCurrent();
            buy_order_count = 1;
            
            // Place pending grid
            PlacePendingGrid(true);
        }
    } else {
        current_state = SELL_SEQUENCE_ACTIVE;
        last_divergence_time = TimeCurrent();
        
        // Place market sell order
        double bid = SymbolInfoDouble(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_BID);
        if(trade.Sell(Lots, TradeSymbol == "" ? _Symbol : TradeSymbol, bid, 0, 0, "MACD Grid Sell")) {
            sell_orders[0].ticket = trade.ResultOrder();
            sell_orders[0].price = bid;
            sell_orders[0].is_market = true;
            sell_orders[0].time = TimeCurrent();
            sell_order_count = 1;
            
            // Place pending grid
            PlacePendingGrid(false);
        }
    }
}

//+------------------------------------------------------------------+
//| Place pending grid orders                                        |
//+------------------------------------------------------------------+
void PlacePendingGrid(bool bullish)
{
    double tick_size = SymbolInfoDouble(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
    double step = PendingStepPoints * tick_size;
    
    if(bullish) {
        double base_price = buy_orders[0].price - step;
        
        for(int i = 1; i <= PendingCount; i++) {
            double price = NormalizeDouble(base_price - (i - 1) * step, _Digits);
            
            if(trade.BuyLimit(Lots, price, TradeSymbol == "" ? _Symbol : TradeSymbol, 0, 0, 
                             ORDER_TIME_DAY, 0, "MACD Grid Buy Limit")) {
                buy_orders[i].ticket = trade.ResultOrder();
                buy_orders[i].price = price;
                buy_orders[i].is_market = false;
                buy_orders[i].time = TimeCurrent();
                buy_order_count++;
            }
        }
    } else {
        double base_price = sell_orders[0].price + step;
        
        for(int i = 1; i <= PendingCount; i++) {
            double price = NormalizeDouble(base_price + (i - 1) * step, _Digits);
            
            if(trade.SellLimit(Lots, price, TradeSymbol == "" ? _Symbol : TradeSymbol, 0, 0, 
                              ORDER_TIME_DAY, 0, "MACD Grid Sell Limit")) {
                sell_orders[i].ticket = trade.ResultOrder();
                sell_orders[i].price = price;
                sell_orders[i].is_market = false;
                sell_orders[i].time = TimeCurrent();
                sell_order_count++;
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Manage buy sequence                                              |
//+------------------------------------------------------------------+
void ManageBuySequence()
{
    // Update order tracking from pending to positions
    UpdateOrderTracking(true);
    
    int active_count = CountActiveOrders(true);
    
    if(active_count == 0) {
        CloseAllAndReset();
        return;
    }
    
    UpdateTPRules(true);
}

//+------------------------------------------------------------------+
//| Manage sell sequence                                             |
//+------------------------------------------------------------------+
void ManageSellSequence()
{
    // Update order tracking from pending to positions
    UpdateOrderTracking(false);
    
    int active_count = CountActiveOrders(false);
    
    if(active_count == 0) {
        CloseAllAndReset();
        return;
    }
    
    UpdateTPRules(false);
}

//+------------------------------------------------------------------+
//| Update order tracking from pending to positions                  |
//+------------------------------------------------------------------+
void UpdateOrderTracking(bool bullish)
{
    if(bullish) {
        for(int i = 0; i < buy_order_count; i++) {
            if(buy_orders[i].ticket > 0) {
                // Check if this is now a position
                if(PositionSelectByTicket(buy_orders[i].ticket)) {
                    // Order became a position, keep tracking
                    continue;
                } else {
                    // Check if it's still a pending order
                    if(HistoryOrderSelect(buy_orders[i].ticket)) {
                        if(HistoryOrderGetInteger(buy_orders[i].ticket, ORDER_STATE) == ORDER_STATE_FILLED) {
                            // Order was filled, find the corresponding position
                            for(int j = 0; j < PositionsTotal(); j++) {
                                if(PositionGetTicket(j) > 0) {
                                    if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
                                       PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                                        // This might be our position, update ticket
                                        buy_orders[i].ticket = PositionGetTicket(j);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    } else {
        for(int i = 0; i < sell_order_count; i++) {
            if(sell_orders[i].ticket > 0) {
                // Check if this is now a position
                if(PositionSelectByTicket(sell_orders[i].ticket)) {
                    // Order became a position, keep tracking
                    continue;
                } else {
                    // Check if it's still a pending order
                    if(HistoryOrderSelect(sell_orders[i].ticket)) {
                        if(HistoryOrderGetInteger(sell_orders[i].ticket, ORDER_STATE) == ORDER_STATE_FILLED) {
                            // Order was filled, find the corresponding position
                            for(int j = 0; j < PositionsTotal(); j++) {
                                if(PositionGetTicket(j) > 0) {
                                    if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
                                       PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
                                        // This might be our position, update ticket
                                        sell_orders[i].ticket = PositionGetTicket(j);
                                        break;
                                    }
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
//| Count active orders                                              |
//+------------------------------------------------------------------+
int CountActiveOrders(bool bullish)
{
    int count = 0;
    
    if(bullish) {
        for(int i = 0; i < buy_order_count; i++) {
            if(buy_orders[i].ticket > 0 && PositionSelectByTicket(buy_orders[i].ticket)) {
                if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                    count++;
                }
            }
        }
    } else {
        for(int i = 0; i < sell_order_count; i++) {
            if(sell_orders[i].ticket > 0 && PositionSelectByTicket(sell_orders[i].ticket)) {
                if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
                    count++;
                }
            }
        }
    }
    
    return count;
}

//+------------------------------------------------------------------+
//| Update TP rules                                                  |
//+------------------------------------------------------------------+
void UpdateTPRules(bool bullish)
{
    int active_count = CountActiveOrders(bullish);
    
    if(active_count < 2) return;
    
    // Check if any TP was hit
    if(CheckTPHit(bullish)) {
        CloseAllAndReset();
        return;
    }
    
    double tp_price = 0;
    bool set_tp = false;
    
    if(active_count == 2) {
        // Set TP to 1000 points
        if(UseAverageTP) {
            tp_price = CalculateAveragePrice(bullish) + 
                      (bullish ? 1 : -1) * TP1PointsWhen2Active * 
                      SymbolInfoDouble(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
        } else {
            tp_price = (bullish ? SymbolInfoDouble(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_ASK) :
                        SymbolInfoDouble(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_BID)) + 
                      (bullish ? 1 : -1) * TP1PointsWhen2Active * 
                      SymbolInfoDouble(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_TRADE_TICK_SIZE);
        }
        set_tp = true;
    } else if(active_count >= 3) {
        // Set TP to first market order entry price
        if(bullish) {
            tp_price = buy_orders[0].price;
        } else {
            tp_price = sell_orders[0].price;
        }
        set_tp = true;
    }
    
    if(set_tp) {
        SetTPForOrders(bullish, tp_price);
    }
}

//+------------------------------------------------------------------+
//| Check if any TP was hit                                          |
//+------------------------------------------------------------------+
bool CheckTPHit(bool bullish)
{
    if(bullish) {
        for(int i = 0; i < buy_order_count; i++) {
            if(buy_orders[i].ticket > 0 && PositionSelectByTicket(buy_orders[i].ticket)) {
                if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                    double tp = PositionGetDouble(POSITION_TP);
                    if(tp > 0) {
                        double current_price = SymbolInfoDouble(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_BID);
                        if(current_price >= tp) {
                            Print("TP hit for buy position: ", buy_orders[i].ticket);
                            return true;
                        }
                    }
                }
            }
        }
    } else {
        for(int i = 0; i < sell_order_count; i++) {
            if(sell_orders[i].ticket > 0 && PositionSelectByTicket(sell_orders[i].ticket)) {
                if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
                    double tp = PositionGetDouble(POSITION_TP);
                    if(tp > 0) {
                        double current_price = SymbolInfoDouble(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_ASK);
                        if(current_price <= tp) {
                            Print("TP hit for sell position: ", sell_orders[i].ticket);
                            return true;
                        }
                    }
                }
            }
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Calculate average price of active orders                         |
//+------------------------------------------------------------------+
double CalculateAveragePrice(bool bullish)
{
    double total_price = 0;
    int count = 0;
    
    if(bullish) {
        for(int i = 0; i < buy_order_count; i++) {
            if(buy_orders[i].ticket > 0 && PositionSelectByTicket(buy_orders[i].ticket)) {
                if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                    total_price += PositionGetDouble(POSITION_PRICE_OPEN);
                    count++;
                }
            }
        }
    } else {
        for(int i = 0; i < sell_order_count; i++) {
            if(sell_orders[i].ticket > 0 && PositionSelectByTicket(sell_orders[i].ticket)) {
                if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
                    total_price += PositionGetDouble(POSITION_PRICE_OPEN);
                    count++;
                }
            }
        }
    }
    
    return count > 0 ? total_price / count : 0;
}

//+------------------------------------------------------------------+
//| Set TP for all orders                                            |
//+------------------------------------------------------------------+
void SetTPForOrders(bool bullish, double tp_price)
{
    if(bullish) {
        for(int i = 0; i < buy_order_count; i++) {
            if(buy_orders[i].ticket > 0 && PositionSelectByTicket(buy_orders[i].ticket)) {
                if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                    if(PositionGetDouble(POSITION_TP) != tp_price) {
                        trade.PositionModify(buy_orders[i].ticket, PositionGetDouble(POSITION_SL), tp_price);
                    }
                }
            }
        }
    } else {
        for(int i = 0; i < sell_order_count; i++) {
            if(sell_orders[i].ticket > 0 && PositionSelectByTicket(sell_orders[i].ticket)) {
                if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) {
                    if(PositionGetDouble(POSITION_TP) != tp_price) {
                        trade.PositionModify(sell_orders[i].ticket, PositionGetDouble(POSITION_SL), tp_price);
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Close all orders and reset                                       |
//+------------------------------------------------------------------+
void CloseAllAndReset()
{
    // Close all positions
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(PositionGetTicket(i) > 0) {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
                trade.PositionClose(PositionGetTicket(i));
            }
        }
    }
    
    // Delete all pending orders
    for(int i = OrdersTotal() - 1; i >= 0; i--) {
        if(OrderGetTicket(i) > 0) {
            if(OrderGetInteger(ORDER_MAGIC) == MagicNumber) {
                trade.OrderDelete(OrderGetTicket(i));
            }
        }
    }
    
    // Reset state
    current_state = IDLE;
    ResetOrderTracking();
    
    Print("All orders closed and state reset");
}

//+------------------------------------------------------------------+
//| Reset order tracking                                             |
//+------------------------------------------------------------------+
void ResetOrderTracking()
{
    buy_order_count = 0;
    sell_order_count = 0;
    
    for(int i = 0; i < 10; i++) {
        buy_orders[i].ticket = 0;
        buy_orders[i].price = 0;
        buy_orders[i].is_market = false;
        buy_orders[i].time = 0;
        
        sell_orders[i].ticket = 0;
        sell_orders[i].price = 0;
        sell_orders[i].is_market = false;
        sell_orders[i].time = 0;
    }
}

//+------------------------------------------------------------------+
//| Recover state from existing positions                            |
//+------------------------------------------------------------------+
void RecoverState()
{
    // Check for existing positions
    bool has_buy_positions = false;
    bool has_sell_positions = false;
    
    for(int i = 0; i < PositionsTotal(); i++) {
        if(PositionGetTicket(i) > 0) {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
                if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                    has_buy_positions = true;
                } else {
                    has_sell_positions = true;
                }
            }
        }
    }
    
    if(has_buy_positions) {
        current_state = BUY_SEQUENCE_ACTIVE;
    } else if(has_sell_positions) {
        current_state = SELL_SEQUENCE_ACTIVE;
    }
}

//+------------------------------------------------------------------+
//| Update display information                                        |
//+------------------------------------------------------------------+
void UpdateDisplay()
{
    string info = "";
    info += "MACD Grid EA v1.0\n";
    info += "State: ";
    
    switch(current_state) {
        case IDLE:
            info += "IDLE - Waiting for divergence";
            break;
        case BUY_SEQUENCE_ACTIVE:
            info += "BUY SEQUENCE ACTIVE\n";
            info += "Active Orders: " + IntegerToString(CountActiveOrders(true)) + "\n";
            break;
        case SELL_SEQUENCE_ACTIVE:
            info += "SELL SEQUENCE ACTIVE\n";
            info += "Active Orders: " + IntegerToString(CountActiveOrders(false)) + "\n";
            break;
    }
    
    info += "Spread: " + IntegerToString((int)SymbolInfoInteger(TradeSymbol == "" ? _Symbol : TradeSymbol, SYMBOL_SPREAD)) + " pts\n";
    info += "Magic: " + IntegerToString(MagicNumber);
    
    Comment(info);
}

//+------------------------------------------------------------------+
