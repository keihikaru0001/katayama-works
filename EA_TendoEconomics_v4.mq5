//+------------------------------------------------------------------+
//| EA: TendoEconomics v4.0 — Hedge Scalp Edition                    |
//|                                                                  |
//| Author  : Yoshimitsu Katayama                                    |
//|           ORCID: 0009-0006-2290-6593                             |
//|           TheYKHC Research / https://theykhc.com                |
//|                                                                  |
//| Theory  : V=N/D — Social Transmission Hypothesis                 |
//| Paper   : DOI: 10.5281/zenodo.20093286                           |
//|                                                                  |
//| Mode    : 平常時=SELLスキャルプ（現物ゴールドのヘッジ）             |
//|           GOLDイベント時=全SELL決済→BUY待機（上昇に乗る）           |
//| Target  : XAU/USD                                                |
//| Trigger : IceCube GOLD-class neutrino alert                      |
//+------------------------------------------------------------------+

#property copyright "© 2026 TheYKHC Research / Yoshimitsu Katayama"
#property link      "https://theykhc.com"
#property version   "4.00"
#property description "TendoEconomics EA v4.0 — Hedge Scalp + GOLD Event Switch"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 入力パラメータ                                                     |
//+------------------------------------------------------------------+
input group "=== 平常時SELLスキャルプ ==="
input bool   InpScalpEnable    = true;      // スキャルプ有効
input double InpLotScalp       = 0.05;      // ロット
input int    InpScalpTP_Pips   = 150;       // TP（pips）
input int    InpScalpSL_Pips   = 80;        // SL（pips）
input int    InpScalpMaxTrades  = 2;        // 同時最大ポジション数
input int    InpEMA_Fast       = 8;         // EMA 短期
input int    InpEMA_Slow       = 21;        // EMA 長期
input int    InpRSI_Period     = 14;        // RSI 期間
input int    InpRSI_Sell       = 60;        // RSI SELL条件（以上）
input int    InpRSI_Buy        = 40;        // RSI BUY条件（以下）※イベント時のみ
input int    InpTrailStart     = 80;        // トレイリング開始（pips利益）
input int    InpTrailStep      = 30;        // トレイリング幅（pips）

input group "=== GOLDイベント時BUY ==="
input bool   InpEventBuy       = true;      // イベント時BUY有効
input double InpLotEvent       = 0.1;       // イベント時ロット
input int    InpEventTP_Pips   = 500;       // イベントBUY TP（pips）
input int    InpEventSL_Pips   = 200;       // イベントBUY SL（pips）
input int    InpEventHoldHours = 72;        // イベントBUY 保有時間

input group "=== IceCube監視 ==="
input bool   InpAutoFetch      = true;
input int    InpFetchIntervalH = 6;
input int    InpCooldownHours  = 168;
input bool   InpManualTrigger  = false;

input group "=== DB記録 ==="
input bool   InpDBRecord       = true;
input string InpDBEndpoint     = "https://app.base44.com/api/apps/69d570145faf332412ad4c73/entities";
input string InpDBApiKey       = "";
input int    InpTickSampleSec  = 30;
input int    InpTickRecordMin  = 60;

input group "=== 平常時ベースライン記録 ==="
input bool   InpBaselineRecord = true;
input int    InpBaselineHour   = 10;        // 毎日記録開始時刻（サーバー時間）
input int    InpBaselineDurMin = 60;

input group "=== リスク管理 ==="
input double InpMaxDailyLoss   = 2.0;       // 1日最大損失（%）

//+------------------------------------------------------------------+
//| グローバル変数                                                     |
//+------------------------------------------------------------------+
CTrade trade;

// GOLDイベント状態
bool     g_alertActive     = false;
datetime g_alertTime       = 0;
string   g_eventId         = "";
datetime g_lastFetchTime   = 0;
datetime g_lastAlertTime   = 0;

// イベントBUYポジション管理
bool     g_eventBuyOpen    = false;
datetime g_eventBuyTime    = 0;

// リスク
double   g_dayStartBalance = 0;
datetime g_dayStart        = 0;

// DB記録
double   g_baselineDensity = 2.5;
double   g_prevBid         = 0;
datetime g_windowStart     = 0;
int      g_windowTicks     = 0;
int      g_recordCount     = 0;

// ベースライン
bool     g_baselineActive  = false;
datetime g_baselineStart   = 0;
datetime g_baselineLastDay = 0;
int      g_baselineWinTicks= 0;
datetime g_baselineWinStart= 0;
double   g_baselinePrevBid = 0;
int      g_baselineCount   = 0;
double   g_blDensitySum    = 0;
double   g_blDensityCount  = 0;

//+------------------------------------------------------------------+
//| ユーティリティ                                                     |
//+------------------------------------------------------------------+
string JsonEscape(string s)
{
   StringReplace(s,"\\","\\\\");
   StringReplace(s,"\"","\\\"");
   return s;
}

bool SendToBase44(string entityName, string jsonBody)
{
   if(!InpDBRecord || StringLen(InpDBApiKey)==0) return false;
   string url     = InpDBEndpoint + "/" + entityName;
   string headers = "Content-Type: application/json\r\nx-api-key: " + InpDBApiKey + "\r\n";
   char post[], result[];
   string resHeaders;
   StringToCharArray(jsonBody, post, 0, StringLen(jsonBody));
   int res = WebRequest("POST", url, headers, 10000, post, result, resHeaders);
   if(res==200||res==201){ Print("[DB] OK: ",entityName); return true; }
   Print("[DB] FAIL: ",res," ",entityName);
   return false;
}

string GetWindow(double sec)
{
   if(sec <  30) return "0-30s";
   if(sec <  60) return "30-60s";
   if(sec < 120) return "1-2min";
   if(sec < 300) return "2-5min";
   if(sec < 900) return "5-15min";
   if(sec <1800) return "15-30min";
   return "30-60min";
}

double PipsToPrice(int pips)
{
   return pips * SymbolInfoDouble("XAUUSD", SYMBOL_POINT) * 10.0;
}

//+------------------------------------------------------------------+
//| 日次リスクチェック                                                 |
//+------------------------------------------------------------------+
bool DailyRiskOK()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   if(g_dayStart != today)
   {
      g_dayStart        = today;
      g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   double loss = (g_dayStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / g_dayStartBalance * 100.0;
   if(loss >= InpMaxDailyLoss)
   {
      Print("[Risk] 日次損失上限到達 loss=", DoubleToString(loss,2), "%");
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| 平常時 SELLスキャルプ                                              |
//+------------------------------------------------------------------+
void ScalpSellCheck()
{
   if(!InpScalpEnable) return;
   if(g_alertActive) return;       // イベント中はスキャルプ停止
   if(!DailyRiskOK()) return;

   // 既存ポジション数カウント
   int cnt = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == "XAUUSD" &&
         PositionGetInteger(POSITION_MAGIC) == 20260525+10) cnt++;
   }
   if(cnt >= InpScalpMaxTrades) return;

   // インジケーター
   double emaF = iMA("XAUUSD", PERIOD_M5, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   double emaS = iMA("XAUUSD", PERIOD_M5, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   double rsi  = iRSI("XAUUSD", PERIOD_M5, InpRSI_Period, PRICE_CLOSE);
   double bid  = SymbolInfoDouble("XAUUSD", SYMBOL_BID);

   // SELL条件：EMA下向き + RSI高め
   bool sellSignal = (emaF < emaS) && (rsi >= InpRSI_Sell) && (bid < emaF);

   if(sellSignal)
   {
      double sl = bid + PipsToPrice(InpScalpSL_Pips);
      double tp = bid - PipsToPrice(InpScalpTP_Pips);
      trade.SetExpertMagicNumber(20260525+10);
      trade.SetDeviationInPoints(30);
      if(trade.Sell(InpLotScalp, "XAUUSD", bid, sl, tp,
         StringFormat("v4_Scalp_S rsi=%.1f ema=%.2f/%.2f", rsi, emaF, emaS)))
         Print("[Scalp] SELL エントリー bid=", bid, " TP=", tp, " SL=", sl);
   }
}

//+------------------------------------------------------------------+
//| トレイリングストップ（平常時SELL用）                                |
//+------------------------------------------------------------------+
void TrailingStop()
{
   double pt = SymbolInfoDouble("XAUUSD", SYMBOL_POINT) * 10.0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) != "XAUUSD") continue;
      if(PositionGetInteger(POSITION_MAGIC) != 20260525+10) continue;
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double bid       = SymbolInfoDouble("XAUUSD", SYMBOL_BID);
      double profit    = (openPrice - bid) / pt;

      if(profit >= InpTrailStart)
      {
         double newSL = bid + PipsToPrice(InpTrailStep);
         if(newSL < curSL || curSL == 0)
         {
            trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            Print("[Trail] SL更新 ", curSL, " → ", newSL);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| GOLDイベント検出時：全SELLをクローズ                               |
//+------------------------------------------------------------------+
void CloseAllScalpSells()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) != "XAUUSD") continue;
      if(PositionGetInteger(POSITION_MAGIC) != 20260525+10) continue;
      Print("[Event] SELLクローズ ticket=", ticket);
      trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| GOLDイベント時：BUYエントリー                                      |
//+------------------------------------------------------------------+
void EventBuyEntry()
{
   if(!InpEventBuy || g_eventBuyOpen) return;
   if(!DailyRiskOK()) return;

   double ask = SymbolInfoDouble("XAUUSD", SYMBOL_ASK);
   double sl  = ask - PipsToPrice(InpEventSL_Pips);
   double tp  = ask + PipsToPrice(InpEventTP_Pips);

   trade.SetExpertMagicNumber(20260525+20);
   trade.SetDeviationInPoints(20);
   if(trade.Buy(InpLotEvent, "XAUUSD", ask, sl, tp,
      StringFormat("v4_EventBUY e=%s", g_eventId)))
   {
      g_eventBuyOpen = true;
      g_eventBuyTime = TimeCurrent();
      Print("[Event] BUY エントリー ask=", ask, " e=", g_eventId);
   }
}

//+------------------------------------------------------------------+
//| イベントBUY 時間クローズ                                           |
//+------------------------------------------------------------------+
void EventBuyManage()
{
   if(!g_eventBuyOpen) return;
   if(TimeCurrent() - g_eventBuyTime < InpEventHoldHours * 3600) return;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == "XAUUSD" &&
         PositionGetInteger(POSITION_MAGIC) == 20260525+20)
      {
         trade.PositionClose(ticket);
         Print("[Event] BUY 時間クローズ ticket=", ticket);
      }
   }
   g_eventBuyOpen = false;
   g_alertActive  = false;
   Print("[Event] イベントモード終了");
}

//+------------------------------------------------------------------+
//| DB: tick記録（イベント時）                                         |
//+------------------------------------------------------------------+
void RecordTickSnapshot(string window, double density, double velocity,
                        double spread, double volume, double bid, double ask)
{
   double secondsAfter = (double)(TimeCurrent() - g_alertTime);
   double anomaly = 0;
   if(g_baselineDensity > 0)
      anomaly = MathMax(MathMin((density - g_baselineDensity)/g_baselineDensity, 1.0), 0);

   string json = StringFormat(
      "{\"event_id\":\"%s\","
      "\"symbol\":\"XAUUSD\","
      "\"seconds_after_gcn\":%.1f,"
      "\"tick_density\":%.4f,"
      "\"bid_velocity\":%.6f,"
      "\"spread\":%.2f,"
      "\"volume\":%.1f,"
      "\"bid\":%.2f,"
      "\"ask\":%.2f,"
      "\"anomaly_score\":%.4f,"
      "\"window\":\"%s\","
      "\"note\":\"EA_v4.0_event\"}",
      JsonEscape(g_eventId), secondsAfter,
      density, velocity, spread, volume, bid, ask,
      anomaly, JsonEscape(window));
   SendToBase44("FxTickSnapshot", json);

   double resonance = (g_baselineDensity > 0) ?
      (density - g_baselineDensity) / g_baselineDensity : 0;
   bool isRes = (resonance > 0.5);
   string jsonBW = StringFormat(
      "{\"event_id\":\"%s\","
      "\"seconds_after_gcn\":%.1f,"
      "\"proxy_type\":\"tick_density\","
      "\"proxy_value\":%.4f,"
      "\"baseline_value\":%.4f,"
      "\"resonance_score\":%.4f,"
      "\"is_resonance_point\":%s,"
      "\"note\":\"EA_v4.0_event\"}",
      JsonEscape(g_eventId), secondsAfter,
      density, g_baselineDensity,
      resonance, isRes ? "true" : "false");
   SendToBase44("BrainwaveProxy", jsonBW);

   g_recordCount++;
}

void SampleTick()
{
   if(!g_alertActive || !InpDBRecord) return;
   double secondsAfter = (double)(TimeCurrent() - g_alertTime);
   if(secondsAfter > InpTickRecordMin * 60) return;

   g_windowTicks++;
   MqlTick tick;
   if(!SymbolInfoTick("XAUUSD", tick)) return;

   double bid    = tick.bid;
   double ask    = tick.ask;
   double spread = (ask - bid) / SymbolInfoDouble("XAUUSD", SYMBOL_POINT) / 10.0;
   double volume = (double)tick.volume;
   if(g_windowStart == 0) g_windowStart = TimeCurrent();
   double elapsed = (double)(TimeCurrent() - g_windowStart);

   if(elapsed >= InpTickSampleSec)
   {
      double density  = (elapsed > 0) ? g_windowTicks / elapsed : 0;
      double velocity = 0;
      if(g_prevBid > 0 && elapsed > 0)
         velocity = MathAbs(bid - g_prevBid) /
                    (SymbolInfoDouble("XAUUSD", SYMBOL_POINT) * 10.0) / elapsed;

      RecordTickSnapshot(GetWindow(secondsAfter), density, velocity,
                         spread, volume, bid, ask);
      g_windowStart = TimeCurrent();
      g_windowTicks = 0;
      g_prevBid     = bid;
   }
}

//+------------------------------------------------------------------+
//| DB: ベースライン記録                                               |
//+------------------------------------------------------------------+
void RecordBaseline(double density, double velocity,
                    double spread, double volume, double bid, double ask)
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   string blId = StringFormat("BASELINE_%04d%02d%02d", dt.year, dt.mon, dt.day);
   double secFromStart = (double)(TimeCurrent() - g_baselineStart);

   string json = StringFormat(
      "{\"event_id\":\"%s\","
      "\"symbol\":\"XAUUSD\","
      "\"seconds_after_gcn\":%.1f,"
      "\"tick_density\":%.4f,"
      "\"bid_velocity\":%.6f,"
      "\"spread\":%.2f,"
      "\"volume\":%.1f,"
      "\"bid\":%.2f,"
      "\"ask\":%.2f,"
      "\"anomaly_score\":0.0,"
      "\"window\":\"%s\","
      "\"note\":\"BASELINE_v4\"}",
      blId, secFromStart,
      density, velocity, spread, volume, bid, ask,
      GetWindow(secFromStart));
   SendToBase44("FxTickSnapshot", json);

   string jsonBW = StringFormat(
      "{\"event_id\":\"%s\","
      "\"seconds_after_gcn\":%.1f,"
      "\"proxy_type\":\"tick_density\","
      "\"proxy_value\":%.4f,"
      "\"baseline_value\":%.4f,"
      "\"resonance_score\":0.0,"
      "\"is_resonance_point\":false,"
      "\"note\":\"BASELINE_v4\"}",
      blId, secFromStart, density, density);
   SendToBase44("BrainwaveProxy", jsonBW);

   g_blDensitySum   += density;
   g_blDensityCount += 1;
   if(g_blDensityCount > 0)
      g_baselineDensity = g_blDensitySum / g_blDensityCount;

   g_baselineCount++;
}

void BaselineSample()
{
   if(!InpBaselineRecord || g_alertActive) return;

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime today = (datetime)StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   bool newDay = (g_baselineLastDay != today);

   if(!g_baselineActive)
   {
      if(dt.hour == InpBaselineHour && newDay)
      {
         g_baselineActive    = true;
         g_baselineStart     = TimeCurrent();
         g_baselineWinStart  = TimeCurrent();
         g_baselineWinTicks  = 0;
         g_baselinePrevBid   = 0;
         g_baselineLastDay   = today;
         Print("[Baseline] 開始: ", TimeToString(TimeCurrent()));
      }
      return;
   }

   if(TimeCurrent() - g_baselineStart >= InpBaselineDurMin * 60)
   {
      g_baselineActive = false;
      Print("[Baseline] 終了 件数=", g_baselineCount, " avg_density=",
            DoubleToString(g_baselineDensity,3));
      return;
   }

   g_baselineWinTicks++;
   MqlTick tick;
   if(!SymbolInfoTick("XAUUSD", tick)) return;

   double bid    = tick.bid;
   double ask    = tick.ask;
   double spread = (ask - bid) / SymbolInfoDouble("XAUUSD", SYMBOL_POINT) / 10.0;
   double volume = (double)tick.volume;
   double elapsed = (double)(TimeCurrent() - g_baselineWinStart);

   if(elapsed >= InpTickSampleSec)
   {
      double density  = (elapsed > 0) ? g_baselineWinTicks / elapsed : 0;
      double velocity = 0;
      if(g_baselinePrevBid > 0 && elapsed > 0)
         velocity = MathAbs(bid - g_baselinePrevBid) /
                    (SymbolInfoDouble("XAUUSD", SYMBOL_POINT) * 10.0) / elapsed;

      RecordBaseline(density, velocity, spread, volume, bid, ask);
      g_baselineWinStart  = TimeCurrent();
      g_baselineWinTicks  = 0;
      g_baselinePrevBid   = bid;
   }
}

//+------------------------------------------------------------------+
//| GCN取得                                                           |
//+------------------------------------------------------------------+
bool FetchIceCubeAlert()
{
   if(TimeCurrent()-g_lastAlertTime < InpCooldownHours*3600) return false;
   if(TimeCurrent()-g_lastFetchTime < InpFetchIntervalH*3600) return false;
   g_lastFetchTime = TimeCurrent();

   string headers = "User-Agent: TendoEconomics-EA/4.0\r\n";
   char post[], result[]; string resH;
   int res = WebRequest("GET","https://gcn.nasa.gov/circulars.atom",
                        headers, 5000, post, result, resH);
   if(res != 200 || ArraySize(result) == 0) return false;

   string atom = CharArrayToString(result);
   string pat  = "circulars/";
   int pos=0, checked=0;
   while(checked < 5)
   {
      int idx = StringFind(atom, pat, pos);
      if(idx < 0) break;
      string idStr = "";
      int st = idx + StringLen(pat);
      for(int k=st; k<st+6; k++){
         ushort c = StringGetCharacter(atom, k);
         if(c>='0' && c<='9') idStr += ShortToString(c);
         else break;
      }
      if(StringLen(idStr)==0){pos=idx+1; continue;}
      char r2[]; string url2 = "https://gcn.nasa.gov/circulars/"+idStr+".json";
      int r2c = WebRequest("GET", url2, headers, 5000, post, r2, resH);
      if(r2c==200 && ArraySize(r2)>0)
      {
         string body = CharArrayToString(r2);
         bool hasIC = (StringFind(body,"IceCube")>=0 || StringFind(body,"icecube")>=0);
         bool hasGO = (StringFind(body,"GOLD")>=0 || StringFind(body,"astrophysical neutrino")>=0);
         if(hasIC && hasGO)
         {
            g_eventId       = idStr;
            g_lastAlertTime = TimeCurrent();
            Print("[TendoEcon v4] ★★★ GOLDイベント検出! Circular=", idStr);

            // NeutrinoEvent 登録
            MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
            string session = "London";
            int h = dt.hour;
            if(h>=0  && h<8)  session="Tokyo";
            if(h>=8  && h<16) session="London";
            if(h>=13 && h<22) session="NewYork";
            string gcnTime = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES);
            string jsonNE = StringFormat(
               "{\"event_id\":\"%s\","
               "\"gcn_publish_time\":\"%s\","
               "\"event_type\":\"GOLD\","
               "\"session\":\"%s\","
               "\"note\":\"EA_v4.0_auto\"}",
               JsonEscape(idStr), JsonEscape(gcnTime), session);
            SendToBase44("NeutrinoEvent", jsonNE);
            return true;
         }
      }
      pos=idx+1; checked++;
   }
   return false;
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== TendoEconomics v4.0 起動 ===");
   Print("モード: 平常時=SELLスキャルプ / GOLDイベント時=BUY切替");
   Print("DB記録: ", InpDBRecord ? "有効" : "無効");
   Print("スキャルプ: ", InpScalpEnable ? "有効" : "無効");
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_lastFetchTime   = TimeCurrent() - InpFetchIntervalH * 3600; // 初回即時チェック
   EventSetTimer(30);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("=== TendoEconomics v4.0 停止 ===");
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // ベースライン記録
   BaselineSample();

   // イベントDB記録
   SampleTick();

   // イベント中：BUY管理
   if(g_alertActive)
   {
      EventBuyManage();
      return; // イベント中はスキャルプしない
   }

   // 平常時：SELLスキャルプ
   ScalpSellCheck();
   TrailingStop();
}

//+------------------------------------------------------------------+
//| OnTimer（6時間ごと GCN監視）                                       |
//+------------------------------------------------------------------+
void OnTimer()
{
   // 手動トリガー
   if(InpManualTrigger && !g_alertActive)
   {
      Print("[Manual] GOLDイベント手動トリガー");
      g_alertActive  = true;
      g_alertTime    = TimeCurrent();
      g_eventId      = "MANUAL_TEST";
      g_windowStart  = 0;
      g_windowTicks  = 0;
      g_recordCount  = 0;

      CloseAllScalpSells();
      EventBuyEntry();
      return;
   }

   // GCN自動取得
   if(InpAutoFetch && !g_alertActive)
   {
      if(FetchIceCubeAlert())
      {
         g_alertActive = true;
         g_alertTime   = TimeCurrent();
         g_windowStart = 0;
         g_windowTicks = 0;
         g_recordCount = 0;

         // ① 全SELLをクローズ（現物ゴールドのヘッジ解除）
         CloseAllScalpSells();

         // ② BUYエントリー（上昇に乗る）
         EventBuyEntry();
      }
   }
}

//+------------------------------------------------------------------+
