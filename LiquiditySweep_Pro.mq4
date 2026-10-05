//+------------------------------------------------------------------+
//|                                          LiquiditySweep_Pro.mq4  |
//|  Снятие ликвидности (SMC) + подтверждение сломом структуры.      |
//|  Одна позиция за раз, реальный SL за экстремумом свипа,          |
//|  фиксированный риск в % на сделку. Без мартингейла и усреднения. |
//+------------------------------------------------------------------+
#property copyright "Sovetnik"
#property version   "3.00"
#property description "Свип экстремума за RangePeriod баров + подтверждение закрытием за противоположный край бара-свипа."
#property description "Сигналы только по закрытым барам. SL за фитилём свипа, TP = R x RewardRatio, безубыток, лимиты риска."
#property strict

//=== Сигнал ===
input int    RangePeriod         = 20;     // Баров для поиска пула ликвидности (экстремумов)
input int    ConfirmBars         = 3;      // Баров на подтверждение (0 = вход сразу по свипу)
input double MaxSweepATR         = 2.0;    // Макс. глубина прокола уровня, в ATR
input double MinWickRatio        = 0.0;    // Мин. доля фитиля в баре-свипе (0..1)
input int    ATRPeriod           = 14;     // Период ATR
//=== Фильтры ===
input bool   UseSession          = true;   // Входить только в торговую сессию
input int    SessionStartHour    = 8;      // Начало сессии (час сервера)
input int    SessionEndHour      = 20;     // Конец сессии (час сервера, не включительно)
input int    TrendMAPeriod       = 0;      // EMA-фильтр тренда (0 = выкл)
input ENUM_TIMEFRAMES TrendTF    = PERIOD_CURRENT; // Таймфрейм EMA-фильтра
input int    MaxSpreadPoints     = 30;     // Макс. спред для входа, пунктов
//=== Стоп и тейк ===
input double SLBufferATR         = 0.1;    // Буфер SL за экстремумом свипа, в ATR
input int    MinSLPoints         = 80;     // Мин. SL, пунктов (меньше - вход пропускается)
input int    MaxSLPoints         = 800;    // Макс. SL, пунктов (больше - вход пропускается)
input double RewardRatio         = 2.0;    // TP = риск x RewardRatio
//=== Сопровождение ===
input double BreakevenAtR        = 1.0;    // Безубыток при прибыли N x R (0 = выкл)
input int    BreakevenLockPoints = 10;     // Фиксируемая прибыль при безубытке, пунктов
input double PartialCloseAtR     = 0.0;    // Частичное закрытие при прибыли N x R (0 = выкл)
input double PartialClosePercent = 50.0;   // Доля частичного закрытия, %
input double TrailATR            = 0.0;    // Трейлинг-стоп на расстоянии N x ATR (0 = выкл)
input int    MaxBarsInTrade      = 0;      // Закрыть позицию через N баров (0 = выкл)
input bool   CloseOnFriday       = true;   // Закрывать позицию перед выходными
input int    FridayCloseHour     = 21;     // Час закрытия в пятницу (сервер)
//=== Риск ===
input double RiskPercent         = 1.0;    // Риск на сделку, % от баланса
input double FixedLot            = 0.0;    // Фиксированный лот (>0 - вместо RiskPercent)
input double MaxLot              = 0.0;    // Ограничение лота (0 = нет)
input double MaxDailyLossPercent = 3.0;    // Дневной лимит убытка, % (0 = выкл)
input double MaxDrawdownPercent  = 30.0;   // Стоп торговли при просадке эквити от пика, % (0 = выкл)
//=== Прочее ===
input int    Slippage            = 10;     // Проскальзывание, пунктов
input bool   ECNMode             = false;  // Ставить SL/TP после открытия (ECN-счета)
input int    Magic               = 220500; // Magic number
input string OrderCommentText    = "LSPro"; // Комментарий к ордерам

//+------------------------------------------------------------------+
//| Сетап: найденный свип, который ждёт подтверждения                |
//+------------------------------------------------------------------+
struct Setup
{
   bool     active;
   double   extreme;   // экстремум бара-свипа (High для SELL, Low для BUY)
   double   trigger;   // противоположный край бара-свипа - уровень подтверждения
   datetime time;      // время открытия бара-свипа
};

Setup    g_sell;
Setup    g_buy;
datetime g_lastBar = 0;
bool     g_halted  = false;
string   g_gvPeak;
string   g_gvPartial;

//+------------------------------------------------------------------+
int OnInit()
{
   bool bad = RangePeriod<2 || ATRPeriod<1 || ConfirmBars<0 || RewardRatio<=0 ||
              (RiskPercent<=0 && FixedLot<=0) || MinSLPoints<0 || MaxSLPoints<=MinSLPoints ||
              SessionStartHour<0 || SessionStartHour>23 || SessionEndHour<0 || SessionEndHour>24 ||
              MinWickRatio<0 || MinWickRatio>=1 || MaxSweepATR<=0 ||
              (PartialCloseAtR>0 && (PartialClosePercent<=0 || PartialClosePercent>=100));
   if(bad)
   {
      Print("LSPro: некорректные входные параметры");
      return INIT_PARAMETERS_INCORRECT;
   }

   ResetSetup(g_sell);
   ResetSetup(g_buy);
   g_lastBar = 0;
   g_halted  = false;

   g_gvPeak    = "LSPro_" + Symbol() + "_" + IntegerToString(Magic) + "_peak";
   g_gvPartial = "LSPro_" + Symbol() + "_" + IntegerToString(Magic) + "_partial";
   if(IsTesting())
   {
      GlobalVariableDel(g_gvPeak);
      GlobalVariableDel(g_gvPartial);
   }
   if(!GlobalVariableCheck(g_gvPeak))
      GlobalVariableSet(g_gvPeak, AccountEquity());

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(Bars < RangePeriod + ATRPeriod + 5) return;

   int ticket = FindPosition();

   // 1. Защита депозита: просадка эквити от пика
   if(DrawdownGuard())
   {
      if(ticket > 0) CloseOrder(ticket, 0, "лимит просадки");
      UpdatePanel();
      return;
   }

   // 2. Закрытие перед выходными
   if(ticket > 0 && IsFridayClose())
   {
      if(CloseOrder(ticket, 0, "пятница")) ticket = -1;
   }

   // 3. Сопровождение открытой позиции (каждый тик)
   if(ticket > 0) ManagePosition(ticket);

   // 4. Поиск сигналов - один раз на новом баре, по закрытому бару 1
   if(Time[0] != g_lastBar)
   {
      g_lastBar = Time[0];
      OnNewBar();
   }

   if(!IsTesting() || IsVisualMode()) UpdatePanel();
}

//+------------------------------------------------------------------+
//| Логика сигнала на закрытом баре 1                                |
//+------------------------------------------------------------------+
void OnNewBar()
{
   // Пока есть позиция, новые сетапы не копим
   if(FindPosition() > 0)
   {
      ResetSetup(g_sell);
      ResetSetup(g_buy);
      return;
   }

   double atr = iATR(Symbol(), 0, ATRPeriod, 1);
   if(atr <= 0) return;

   int    signal  = 0;
   double extreme = 0;

   // 1) Подтверждение ранее найденных свипов
   if(ConfirmBars > 0)
   {
      if(ConfirmSetup(g_sell, -1))     { signal = -1; extreme = g_sell.extreme; }
      else if(ConfirmSetup(g_buy, 1))  { signal =  1; extreme = g_buy.extreme;  }
   }

   // 2) Поиск нового свипа на баре 1
   if(signal == 0)
   {
      int hiIdx = iHighest(Symbol(), 0, MODE_HIGH, RangePeriod, 2);
      int loIdx = iLowest (Symbol(), 0, MODE_LOW,  RangePeriod, 2);
      if(hiIdx < 0 || loIdx < 0) return;

      double levelHi = High[hiIdx];
      double levelLo = Low[loIdx];
      double range   = High[1] - Low[1];
      if(range <= 0) return;

      // SELL: прокол максимума и закрытие обратно под него
      if(High[1] > levelHi && Close[1] < levelHi &&
         High[1] - levelHi <= MaxSweepATR * atr &&
         (High[1] - MathMax(Open[1], Close[1])) / range >= MinWickRatio)
      {
         if(ConfirmBars == 0) { signal = -1; extreme = High[1]; }
         else SetSetup(g_sell, High[1], Low[1], Time[1]);
      }

      // BUY: прокол минимума и закрытие обратно над ним
      if(signal == 0 &&
         Low[1] < levelLo && Close[1] > levelLo &&
         levelLo - Low[1] <= MaxSweepATR * atr &&
         (MathMin(Open[1], Close[1]) - Low[1]) / range >= MinWickRatio)
      {
         if(ConfirmBars == 0) { signal = 1; extreme = Low[1]; }
         else SetSetup(g_buy, Low[1], High[1], Time[1]);
      }
   }

   if(signal == 0) return;

   ResetSetup(g_sell);
   ResetSetup(g_buy);

   if(!EntryAllowed(signal)) return;
   OpenTrade(signal, extreme, atr);
}

//+------------------------------------------------------------------+
//| true - сетап подтверждён закрытием бара 1 за уровнем trigger     |
//+------------------------------------------------------------------+
bool ConfirmSetup(Setup &s, int dir)
{
   if(!s.active) return false;

   int after = iBarShift(Symbol(), 0, s.time) - 1;   // закрытых баров после свипа
   if(after < 1) return false;
   if(after > ConfirmBars) { ResetSetup(s); return false; }

   // Экстремум свипа обновлён - сетап сломан
   if((dir < 0 && High[1] > s.extreme) || (dir > 0 && Low[1] < s.extreme))
   {
      ResetSetup(s);
      return false;
   }

   if(dir < 0 && Close[1] < s.trigger) return true;
   if(dir > 0 && Close[1] > s.trigger) return true;
   return false;
}

void SetSetup(Setup &s, double extremePrice, double triggerPrice, datetime barTime)
{
   s.active  = true;
   s.extreme = extremePrice;
   s.trigger = triggerPrice;
   s.time    = barTime;
}

void ResetSetup(Setup &s)
{
   s.active  = false;
   s.extreme = 0;
   s.trigger = 0;
   s.time    = 0;
}

//+------------------------------------------------------------------+
//| Фильтры входа                                                    |
//+------------------------------------------------------------------+
bool EntryAllowed(int dir)
{
   if(g_halted) return false;
   if(!IsTesting() && !IsTradeAllowed()) return false;

   if(!InSession(TimeHour(Time[0]))) return false;

   datetime now = TimeCurrent();
   if(CloseOnFriday && TimeDayOfWeek(now) == 5 && TimeHour(now) >= FridayCloseHour) return false;

   RefreshRates();
   double spreadPts = (Ask - Bid) / Point;
   if(spreadPts > MaxSpreadPoints)
   {
      Print("LSPro: вход пропущен, спред ", DoubleToString(spreadPts, 0), " > ", MaxSpreadPoints);
      return false;
   }

   if(TrendMAPeriod > 0)
   {
      double ma = iMA(Symbol(), TrendTF, TrendMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
      if(ma <= 0) return false;
      if(dir > 0 && Close[1] < ma) return false;
      if(dir < 0 && Close[1] > ma) return false;
   }

   if(MaxDailyLossPercent > 0)
   {
      double closedToday     = TodayClosedPL();
      double dayStartBalance = AccountBalance() - closedToday;
      if(dayStartBalance > 0 && -closedToday >= dayStartBalance * MaxDailyLossPercent / 100.0)
      {
         Print("LSPro: дневной лимит убытка достигнут, вход пропущен");
         return false;
      }
   }
   return true;
}

bool InSession(int hour)
{
   if(!UseSession) return true;
   if(SessionStartHour < SessionEndHour)
      return hour >= SessionStartHour && hour < SessionEndHour;
   return hour >= SessionStartHour || hour < SessionEndHour;   // сессия через полночь
}

bool IsFridayClose()
{
   if(!CloseOnFriday) return false;
   datetime now = TimeCurrent();
   return TimeDayOfWeek(now) == 5 && TimeHour(now) >= FridayCloseHour;
}

//+------------------------------------------------------------------+
//| Открытие позиции: SL за экстремумом свипа, TP = R x RewardRatio  |
//+------------------------------------------------------------------+
bool OpenTrade(int dir, double extreme, double atr)
{
   int cmd = (dir > 0) ? OP_BUY : OP_SELL;

   for(int attempt = 0; attempt < 3; attempt++)
   {
      RefreshRates();
      double price = (dir > 0) ? Ask : Bid;
      // SELL закрывается по Ask, поэтому к его SL добавляем спред
      double sl    = (dir > 0) ? extreme - SLBufferATR * atr
                               : extreme + SLBufferATR * atr + (Ask - Bid);
      double risk  = (dir > 0) ? price - sl : sl - price;
      if(risk <= 0) return false;

      double riskPts = risk / Point;
      if(riskPts < MinSLPoints || riskPts > MaxSLPoints)
      {
         Print("LSPro: вход пропущен, SL ", DoubleToString(riskPts, 0), " п. вне диапазона ",
               MinSLPoints, "..", MaxSLPoints);
         return false;
      }
      if(risk <= MarketInfo(Symbol(), MODE_STOPLEVEL) * Point)
      {
         Print("LSPro: вход пропущен, SL ближе StopLevel брокера");
         return false;
      }

      double tp  = price + dir * RewardRatio * risk;
      double lot = CalcLot(risk);
      if(lot <= 0)
      {
         Print("LSPro: вход пропущен, расчётный лот меньше минимального");
         return false;
      }

      ResetLastError();
      if(AccountFreeMarginCheck(Symbol(), cmd, lot) <= 0 || GetLastError() == 134)
      {
         Print("LSPro: недостаточно свободной маржи для лота ", DoubleToString(lot, 2));
         return false;
      }

      sl = NormalizeDouble(sl, Digits);
      tp = NormalizeDouble(tp, Digits);

      int ticket = OrderSend(Symbol(), cmd, lot, price, Slippage,
                             ECNMode ? 0.0 : sl, ECNMode ? 0.0 : tp,
                             OrderCommentText, Magic, 0, (dir > 0) ? clrDodgerBlue : clrTomato);
      if(ticket > 0)
      {
         if(ECNMode && OrderSelect(ticket, SELECT_BY_TICKET))
         {
            if(!OrderModify(ticket, OrderOpenPrice(), sl, tp, 0, clrNONE))
               Print("LSPro: не удалось выставить SL/TP #", ticket, " err=", GetLastError());
         }
         Print("LSPro: ", (dir > 0) ? "BUY" : "SELL", " #", ticket,
               " lot=", DoubleToString(lot, 2),
               " SL=", DoubleToString(sl, Digits), " TP=", DoubleToString(tp, Digits),
               " риск=", DoubleToString(riskPts, 0), " п.");
         return true;
      }

      int err = GetLastError();
      Print("LSPro: OrderSend ошибка ", err);
      if(!IsRetryable(err)) return false;
      Sleep(1000);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Сопровождение: выход по времени, частичное закрытие,             |
//| безубыток, трейлинг                                              |
//+------------------------------------------------------------------+
void ManagePosition(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;

   int      type     = OrderType();
   double   open     = OrderOpenPrice();
   double   sl       = OrderStopLoss();
   double   tp       = OrderTakeProfit();
   double   lots     = OrderLots();
   datetime openTime = OrderOpenTime();

   if(MaxBarsInTrade > 0 && iBarShift(Symbol(), 0, openTime) >= MaxBarsInTrade)
   {
      CloseOrder(ticket, 0, "время в сделке");
      return;
   }

   if(tp <= 0) return;                          // без TP исходный риск неизвестен
   double R = MathAbs(tp - open) / RewardRatio; // исходный риск в цене
   if(R <= 0) return;

   RefreshRates();
   double profit = (type == OP_BUY) ? Bid - open : open - Ask;

   // Частичное закрытие (один раз на позицию; остаток получает новый тикет с тем же OpenTime)
   if(PartialCloseAtR > 0 && profit >= PartialCloseAtR * R &&
      openTime != (datetime)GlobalVariableGet(g_gvPartial))
   {
      double minLot = MarketInfo(Symbol(), MODE_MINLOT);
      double part   = FloorLot(lots * PartialClosePercent / 100.0);
      if(part < minLot || lots - part < minLot - 1e-8)
         GlobalVariableSet(g_gvPartial, (double)openTime);   // объём слишком мал - пропускаем
      else if(CloseOrder(ticket, part, "частичное закрытие"))
      {
         GlobalVariableSet(g_gvPartial, (double)openTime);
         return;
      }
   }

   double newSL = sl;

   if(BreakevenAtR > 0 && profit >= BreakevenAtR * R)
   {
      double be = (type == OP_BUY) ? open + BreakevenLockPoints * Point
                                   : open - BreakevenLockPoints * Point;
      if(type == OP_BUY  && (newSL == 0 || be > newSL)) newSL = be;
      if(type == OP_SELL && (newSL == 0 || be < newSL)) newSL = be;
   }

   double trailStartR = (BreakevenAtR > 0) ? BreakevenAtR : 1.0;
   if(TrailATR > 0 && profit >= trailStartR * R)
   {
      double atr   = iATR(Symbol(), 0, ATRPeriod, 1);
      double trail = (type == OP_BUY) ? Bid - TrailATR * atr : Ask + TrailATR * atr;
      if(type == OP_BUY  && trail > newSL)                  newSL = trail;
      if(type == OP_SELL && (newSL == 0 || trail < newSL))  newSL = trail;
   }

   newSL = NormalizeDouble(newSL, Digits);
   if(MathAbs(newSL - sl) < Point / 2) return;

   // SL двигаем только в сторону прибыли и не ближе StopLevel
   double stopLevel = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(type == OP_BUY)
   {
      if(newSL <= sl || newSL >= Bid - stopLevel) return;
   }
   else
   {
      if((sl > 0 && newSL >= sl) || newSL <= Ask + stopLevel) return;
   }

   if(!OrderModify(ticket, open, newSL, tp, 0, clrNONE))
      Print("LSPro: OrderModify #", ticket, " ошибка ", GetLastError());
}

//+------------------------------------------------------------------+
//| Защита по просадке эквити от исторического пика (по всему счёту) |
//+------------------------------------------------------------------+
bool DrawdownGuard()
{
   if(MaxDrawdownPercent <= 0) return false;
   if(g_halted) return true;

   double equity = AccountEquity();
   double peak   = GlobalVariableGet(g_gvPeak);
   if(equity > peak)
   {
      peak = equity;
      GlobalVariableSet(g_gvPeak, peak);
   }
   if(peak > 0 && equity <= peak * (1.0 - MaxDrawdownPercent / 100.0))
   {
      g_halted = true;
      string msg = "LSPro: просадка эквити " + DoubleToString(100.0 * (peak - equity) / peak, 1) +
                   "% от пика, торговля остановлена. Сброс: удалить глобальную переменную " + g_gvPeak;
      Print(msg);
      if(!IsTesting()) Alert(msg);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Вспомогательные функции                                          |
//+------------------------------------------------------------------+
int FindPosition()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() != Magic || OrderSymbol() != Symbol()) continue;
      if(OrderType() == OP_BUY || OrderType() == OP_SELL) return OrderTicket();
   }
   return -1;
}

// lots = 0 - закрыть весь объём
bool CloseOrder(int ticket, double lots, string reason)
{
   for(int attempt = 0; attempt < 3; attempt++)
   {
      RefreshRates();
      if(!OrderSelect(ticket, SELECT_BY_TICKET) || OrderCloseTime() != 0) return false;

      double volume = (lots > 0) ? lots : OrderLots();
      double price  = (OrderType() == OP_BUY) ? Bid : Ask;   // BUY закрывается по Bid, SELL по Ask
      if(OrderClose(ticket, volume, NormalizeDouble(price, Digits), Slippage, clrWhite))
      {
         Print("LSPro: закрыт #", ticket, " объём ", DoubleToString(volume, 2), " (", reason, ")");
         return true;
      }

      int err = GetLastError();
      Print("LSPro: OrderClose #", ticket, " ошибка ", err);
      if(!IsRetryable(err)) return false;
      Sleep(1000);
   }
   return false;
}

// Реквоты, смена цены, нет цен, торговый поток занят
bool IsRetryable(int err)
{
   return err == 135 || err == 136 || err == 138 || err == 146;
}

double CalcLot(double riskPrice)
{
   double lot;
   if(FixedLot > 0)
      lot = FixedLot;
   else
   {
      double tickValue = MarketInfo(Symbol(), MODE_TICKVALUE);
      double tickSize  = MarketInfo(Symbol(), MODE_TICKSIZE);
      if(tickValue <= 0 || tickSize <= 0 || riskPrice <= 0) return 0;
      double lossPerLot = riskPrice / tickSize * tickValue;
      lot = AccountBalance() * RiskPercent / 100.0 / lossPerLot;
   }

   double minLot = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot = MarketInfo(Symbol(), MODE_MAXLOT);
   if(MaxLot > 0) maxLot = MathMin(maxLot, MaxLot);

   lot = FloorLot(lot);
   if(lot < minLot) return 0;   // не превышаем заданный риск ради минимального лота
   if(lot > maxLot) lot = FloorLot(maxLot);
   return lot;
}

double FloorLot(double lot)
{
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0) step = 0.01;
   return NormalizeDouble(MathFloor(lot / step + 1e-9) * step, LotDigits(step));
}

int LotDigits(double step)
{
   int d = 0;
   while(MathAbs(step - MathRound(step)) > 1e-8 && d < 8)
   {
      step *= 10;
      d++;
   }
   return d;
}

// Результат закрытых сегодня сделок этого советника
double TodayClosedPL()
{
   datetime dayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));   // 00:00 сегодня (сервер)
   double   pl = 0;
   for(int i = OrdersHistoryTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY)) continue;
      if(OrderMagicNumber() != Magic || OrderSymbol() != Symbol()) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      if(OrderCloseTime() < dayStart) continue;
      pl += OrderProfit() + OrderSwap() + OrderCommission();
   }
   return pl;
}

string SetupText(Setup &s)
{
   if(!s.active) return "-";
   return DoubleToString(s.extreme, Digits);
}

void UpdatePanel()
{
   double peak = GlobalVariableGet(g_gvPeak);
   double dd   = (peak > 0) ? 100.0 * (peak - AccountEquity()) / peak : 0.0;

   string txt = "Liquidity Sweep Pro\n";
   txt += "Спред: " + DoubleToString((Ask - Bid) / Point, 0) + " п.\n";
   txt += "Сетап SELL: " + SetupText(g_sell) + "   BUY: " + SetupText(g_buy) + "\n";
   txt += "Просадка от пика: " + DoubleToString(MathMax(dd, 0), 1) + "%";
   if(MaxDrawdownPercent > 0) txt += " (лимит " + DoubleToString(MaxDrawdownPercent, 1) + "%)";
   txt += "\n";
   if(g_halted) txt += "ТОРГОВЛЯ ОСТАНОВЛЕНА: лимит просадки\n";
   Comment(txt);
}
//+------------------------------------------------------------------+
