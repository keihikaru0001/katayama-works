//+------------------------------------------------------------------+
//| EA: TendoEconomics v3.2 — Baseline + Event Recording Edition     |
//|                                                                  |
//| Author  : Yoshimitsu Katayama                                    |
//|           ORCID: 0009-0006-2290-6593                             |
//|           TheYKHC Research / https://theykhc.com                |
//|                                                                  |
//| Theory  : V=N/D — Social Transmission Hypothesis                 |
//| Paper   : DOI: 10.5281/zenodo.20093286                           |
//|                                                                  |
//| Mode    : H1 Main + M1 Scalp + Event DB + Baseline DB           |
//| Target  : XAU/USD                                                |
//| Trigger : IceCube GOLD-class neutrino alert                      |
//+------------------------------------------------------------------+

#property copyright "© 2026 TheYKHC Research / Yoshimitsu Katayama"
#property link      "https://theykhc.com"
#property version   "3.20"
#property description "TendoEconomics EA v3.2 — Event + Baseline Recording"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 入力パラメータ                                                     |
//+------------------------------------------------------------------+
input group "=== H1 メインポジション ==="
input double InpLotMain        = 0.1;
input int    InpHoldHours      = 72;
input double InpScoreThreshold = 0.55;
input double InpSL_Pct         = 2.0;
input double InpTP_Pct         = 5.0;

input group "=== M1 スキャルプ ==="
input bool   InpM1Enable       = true;
input double InpLotM1          = 0.05;
input int    InpM1MaxTrades    = 3;
input int    InpM1HoldMin      = 15;
input double InpM1SL_Pips      = 30;
input double InpM1TP_Pips      = 20;
input int    InpM1RSI_Period   = 7;
input int    InpM1RSI_OB       = 65;
input int    InpM1RSI_OS       = 35;
input int    InpM1MA_Fast      = 5;
input int    InpM1MA_Slow      = 13;
input int    InpM1ActiveHours  = 72;

input group "=== IceCube監視 ==="
input bool   InpAutoFetch      = true;
input int    InpFetchIntervalH = 6;
input int    InpCooldownHours  = 168;
input bool   InpManualTrigger  = false;

input group "=== ニュートリノDB記録 ==="
input bool   InpDBRecord       = true;
input string InpDBEndpoint     = "https://app.base44.com/api/apps/69d570145faf332412ad4c73/entities";
input string InpDBApiKey       = "";
input int    InpTickSampleSec  = 30;     // サンプリング間隔（秒）
input int    InpTickRecordMin  = 60;     // イベント後記録継続時間（分）

input group "=== 平常時ベースライン記録 ==="
input bool   InpBaselineRecord = true;   // 平常時記録有効
input int    InpBaselineHour   = 10;     // 毎日記録開始時刻（時・サーバー時間）
input int    InpBaselineDurMin = 60;     // 毎日記録継続時間（分）

input group "=== リスク管理 ==="
input double InpMaxDailyLoss   = 3.0;

//+------------------------------------------------------------------+
//| グローバル変数                                                     |
//+------------------------------------------------------------------+
CTrade trade;

// H1メイン
datetime g_alertTime       = 0;
datetime g_h1EntryTime     = 0;
bool     g_h1Open          = false;
bool     g_alertActive     = false;
string   g_eventId         = "";
double   g_lastScore       = 0.0;

// GCN
datetime g_lastFetchTime   = 0;
datetime g_lastAlertTime   = 0;

// リスク
double   g_dayStartBalance = 0;
datetime g_dayStart        = 0;

// イベント記録
double   g_baselineDensity  = 2.5;
double   g_baselineVelocity = 0.03;
int      g_recordCount      = 0;
double   g_prevBid          = 0;
datetime g_windowStart      = 0;
int      g_windowTicks      = 0;

// 平常時ベースライン記録
bool     g_baselineActive   = false;
datetime g_baselineStart    = 0;
datetime g_baselineLastDay  = 0;
int      g_baselineWinTicks = 0;
datetime g_baselineWinStart = 0;
double   g_baselinePrevBid  = 0;
int      g_baselineCount    = 0;

// ベースライン統計（動的更新）
double   g_blDensitySum     = 0;
double   g_blDensityCount   = 0;

// 指標シンボル
string g_symbols[] = {
   "XAGUSD","XPTUSD","BTCUSD","US500",
   "UKOIL","JP225","USDJPY","CHINAH","GBPUSD"
};
double g_weights[] = {
   0.12, 0.12, 0.10, 0.10,
   0.08, 0.10, 0.08, 0.10, 0.10
};

//+------------------------------------------------------------------+
//| JSON エスケープ                                                    |
//+------------------------------------------------------------------+
string JsonEscape(string s)
{
   StringReplace(s,"\\","\\\\");
   StringReplace(s,"\"","\\\"");
   return s;
}

//+------------------------------------------------------------------+
//| Base44 API送信                                                    |
//+------------------------------------------------------------------+
bool SendToBase44(string entityName, string jsonBody)
{
   if(!InpDBRecord || StringLen(InpDBApiKey)==0) return false;
   string url     = InpDBEndpoint + "/" + entityName;
   string headers = "Content-Type: application/json\r\nx-api-key: " + InpDBApiKey + "\r\n";
   char post[], result[];
   string resHeaders;
   StringToCharArray(jsonBody, post, 0, StringLen(jsonBody));
   int res = WebRequest("POST", url, headers, 10000, post, result, resHeaders);
   if(res==200||res==201){
      Print("[DB] 送信OK: ",entityName);
      return true;
   }
   Print("[DB] 送信失敗: ",res," ",entityName);
   return false;
}

//+------------------------------------------------------------------+
//| 観測窓文字列                                                       |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| 平常時ベースライン記録（FxTickSnapshot + BrainwaveProxy）           |
//| event_id = "BASELINE_YYYYMMDD" で区別                             |
//+------------------------------------------------------------------+
void RecordBaseline(double tickDensity, double bidVelocity,
                    double spread, double volume, double bid, double ask)
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   string blId = StringFormat("BASELINE_%04d%02d%02d", dt.year, dt.mon, dt.day);
   double secFromStart = (double)(TimeCurrent() - g_baselineStart);

   // FxTickSnapshot
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
      "\"note\":\"BASELINE_auto\"}",
      blId, secFromStart,
      tickDensity, bidVelocity,
      spread, volume, bid, ask,
      GetWindow(secFromStart)
   );
   SendToBase44("FxTickSnapshot", json);

   // BrainwaveProxy（ベースライン自身を基準として resonance=0）
   string jsonBW = StringFormat(
      "{\"event_id\":\"%s\","
      "\"seconds_after_gcn\":%.1f,"
      "\"proxy_type\":\"tick_density\","
      "\"proxy_value\":%.4f,"
      "\"baseline_value\":%.4f,"
      "\"resonance_score\":0.0,"
      "\"is_resonance_point\":false,"
      "\"note\":\"BASELINE_auto\"}",
      blId, secFromStart,
      tickDensity, tickDensity
   );
   SendToBase44("BrainwaveProxy", jsonBW);

   // 動的ベースライン更新
   g_blDensitySum   += tickDensity;
   g_blDensityCount += 1;
   if(g_blDensityCount > 0)
      g_baselineDensity = g_blDensitySum / g_blDensityCount;

   g_baselineCount++;
   Print(StringFormat("[Baseline] #%d sec=%.0f density=%.3f baseline_avg=%.3f",
         g_baselineCount, secFromStart, tickDensity, g_baselineDensity));
}

//+------------------------------------------------------------------+
//| 平常時記録ループ（OnTickから呼ぶ）                                  |
//+------------------------------------------------------------------+
void BaselineSample()
{
   if(!InpBaselineRecord) return;
   if(g_alertActive) return;  // イベント中は平常時記録しない

   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);

   // 毎日 InpBaselineHour 時に起動（1日1回）
   bool newDay = (g_baselineLastDay != (datetime)StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day)));

   if(!g_baselineActive)
   {
      if(dt.hour == InpBaselineHour && newDay)
      {
         g_baselineActive   = true;
         g_baselineStart    = TimeCurrent();
         g_baselineWinStart = TimeCurrent();
         g_baselineWinTicks = 0;
         g_baselinePrevBid  = 0;
         g_baselineLastDay  = (datetime)StringToTime(
            StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
         Print("[Baseline] 記録開始: ",TimeToString(TimeCurrent()));
      }
      return;
   }

   // 継続時間チェック
   if(TimeCurrent() - g_baselineStart >= InpBaselineDurMin * 60)
   {
      g_baselineActive = false;
      Print("[Baseline] 記録終了 合計=",g_baselineCount,"件 avg_density=",
            DoubleToString(g_baselineDensity,3));
      return;
   }

   // tick カウント
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

      g_baselineWinStart = TimeCurrent();
      g_baselineWinTicks = 0;
      g_baselinePrevBid  = bid;
   }
}

//+------------------------------------------------------------------+
//| イベント時 tick記録                                                 |
//+------------------------------------------------------------------+
void RecordTickSnapshot(string window, double tickDensity, double bidVelocity,
                        double spread, double volume, double bid, double ask)
{
   if(!g_alertActive || !InpDBRecord) return;

   double secondsAfter = (double)(TimeCurrent() - g_alertTime);
   double anomaly = 0;
   if(g_baselineDensity > 0)
      anomaly = MathMin((tickDensity - g_baselineDensity) / g_baselineDensity, 1.0);
   if(anomaly < 0) anomaly = 0;

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
      "\"note\":\"EA_v3.2_event\"}",
      JsonEscape(g_eventId), secondsAfter,
      tickDensity, bidVelocity,
      spread, volume, bid, ask,
      anomaly, JsonEscape(window)
   );
   SendToBase44("FxTickSnapshot", json);

   double resonance = (g_baselineDensity > 0) ?
      (tickDensity - g_baselineDensity) / g_baselineDensity : 0;
   bool isRes = (resonance > 0.5);

   string jsonBW = StringFormat(
      "{\"event_id\":\"%s\","
      "\"seconds_after_gcn\":%.1f,"
      "\"proxy_type\":\"tick_density\","
      "\"proxy_value\":%.4f,"
      "\"baseline_value\":%.4f,"
      "\"resonance_score\":%.4f,"
      "\"is_resonance_point\":%s,"
      "\"note\":\"EA_v3.2_event\"}",
      JsonEscape(g_eventId), secondsAfter,
      tickDensity, g_baselineDensity,
      resonance, isRes ? "true" : "false"
   );
   SendToBase44("BrainwaveProxy", jsonBW);
   g_recordCount++;
}

//+------------------------------------------------------------------+
//| イベント時 SampleTick                                              |
//+------------------------------------------------------------------+
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
//| NeutrinoEvent 登録                                                |
//+------------------------------------------------------------------+
void RecordNeutrinoEvent(string eventId, string gcnTime, string eventType)
{
   if(!InpDBRecord) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   string session = "London";
   int h = dt.hour;
   if(h>=0  && h<8)  session="Tokyo";
   if(h>=8  && h<16) session="London";
   if(h>=13 && h<22) session="NewYork";

   string json = StringFormat(
      "{\"event_id\":\"%s\","
      "\"gcn_publish_time\":\"%s\","
      "\"event_type\":\"%s\","
      "\"session\":\"%s\","
      "\"note\":\"EA_v3.2_auto_detected\"}",
      JsonEscape(eventId), JsonEscape(gcnTime),
      JsonEscape(eventType), JsonEscape(session)
   );
   SendToBase44("NeutrinoEvent", json);
}

//+------------------------------------------------------------------+
//| 複合スコア                                                         |
//+------------------------------------------------------------------+
double CalcCompositeScore()
{
   double total=0, wsum=0;
   for(int i=0;i<ArraySize(g_symbols);i++)
   {
      double cur  = iClose(g_symbols[i], PERIOD_H1, 0);
      double prev = iClose(g_symbols[i], PERIOD_H1, 72);
      if(cur==0||prev==0) continue;
      double chg = (cur-prev)/prev;
      if(g_symbols[i]=="USDJPY") chg=MathAbs(chg);
      double sc = MathMin(MathAbs(chg)/0.05, 1.0);
      if(chg>0) sc=MathMin(sc*1.15,1.0);
      total+=sc*g_weights[i]; wsum+=g_weights[i];
   }
   return wsum>0 ? total/wsum : 0.0;
}

//+------------------------------------------------------------------+
//| GCN取得                                                           |
//+------------------------------------------------------------------+
bool FetchIceCubeAlert()
{
   if(TimeCurrent()-g_lastAlertTime < InpCooldownHours*3600) return false;
   if(TimeCurrent()-g_lastFetchTime < InpFetchIntervalH*3600) return false;
   g_lastFetchTime=TimeCurrent();

   string headers="User-Agent: TendoEconomics-EA/3.2\r\n";
   char post[],result[]; string resH;
   int res=WebRequest("GET","https://gcn.nasa.gov/circulars.atom",
                      headers,5000,post,result,resH);
   if(res!=200||ArraySize(result)==0) return false;

   string atom=CharArrayToString(result);
   string pat="circulars/";
   int pos=0,checked=0;
   while(checked<5)
   {
      int idx=StringFind(atom,pat,pos);
      if(idx<0) break;
      string idStr="";
      int st=idx+StringLen(pat);
      for(int k=st;k<st+6;k++){
         ushort c=StringGetCharacter(atom,k);
         if(c>='0'&&c<='9') idStr+=ShortToString(c);
         else break;
      }
      if(StringLen(idStr)==0){pos=idx+1;continue;}
      char r2[]; string url2="https://gcn.nasa.gov/circulars/"+idStr+".json";
      int r2c=WebRequest("GET",url2,headers,5000,post,r2,resH);
      if(r2c==200&&ArraySize(r2)>0)
      {
         string body=CharArrayToString(r2);
         bool hasIC=(StringFind(body,"IceCube")>=0||StringFind(body,"icecube")>=0);
         bool hasGO=(StringFind(body,"GOLD")>=0||StringFind(body,"astrophysical neutrino")>=0);
         if(hasIC&&hasGO){
            g_eventId=idStr;
            g_lastAlertTime=TimeCurrent();
            string gcnTime=TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES);
            Print("[TendoEcon v3] ★ GOLDイベント! Circular=",idStr);
            RecordNeutrinoEvent(idStr,gcnTime,"GOLD");
            return true;
         }
      }
      pos=idx+1; checked++;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 日次リスク                                                         |
//+------------------------------------------------------------------+
bool DailyRiskOK()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   datetime today=StringToTime(StringFormat("%04d.%02d.%02d 00:00",dt.year,dt.mon,dt.day));
   if(g_dayStart!=today){g_dayStart=today;g_dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);}
   double loss=(g_dayStartBalance-AccountInfoDouble(ACCOUNT_EQUITY))/g_dayStartBalance*100.0;
   if(loss>=InpMaxDailyLoss){Print("[Risk] 日次損失上限");return false;}
   return true;
}

//+------------------------------------------------------------------+
//| M1スキャルプ                                                       |
//+------------------------------------------------------------------+
void M1ScalpCheck()
{
   if(!InpM1Enable||!g_alertActive) return;
   if(TimeCurrent()-g_alertTime>InpM1ActiveHours*3600) return;
   if(!DailyRiskOK()) return;
   int cnt=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL)=="XAUUSD"&&
         PositionGetInteger(POSITION_MAGIC)==20260525+1) cnt++;
   }
   if(cnt>=InpM1MaxTrades) return;
   double rsi=iRSI("XAUUSD",PERIOD_M1,InpM1RSI_Period,PRICE_CLOSE);
   double maF=iMA("XAUUSD",PERIOD_M1,InpM1MA_Fast,0,MODE_EMA,PRICE_CLOSE);
   double maS=iMA("XAUUSD",PERIOD_M1,InpM1MA_Slow,0,MODE_EMA,PRICE_CLOSE);
   double ask=SymbolInfoDouble("XAUUSD",SYMBOL_ASK);
   double bid=SymbolInfoDouble("XAUUSD",SYMBOL_BID);
   double pt=SymbolInfoDouble("XAUUSD",SYMBOL_POINT);
   double slp=InpM1SL_Pips*pt*10, tpp=InpM1TP_Pips*pt*10;
   trade.SetExpertMagicNumber(20260525+1);
   trade.SetDeviationInPoints(30);
   if((rsi>InpM1RSI_OS&&rsi<60)&&(maF>maS)&&(ask>maF))
      trade.Buy(InpLotM1,"XAUUSD",ask,ask-slp,ask+tpp,
         StringFormat("TendoM1_L rsi=%.1f e=%s",rsi,g_eventId));
   else if((rsi<InpM1RSI_OB&&rsi>40)&&(maF<maS)&&(bid<maF))
      trade.Sell(InpLotM1,"XAUUSD",bid,bid+slp,bid-tpp,
         StringFormat("TendoM1_S rsi=%.1f e=%s",rsi,g_eventId));
}

//+------------------------------------------------------------------+
//| M1時間クローズ                                                     |
//+------------------------------------------------------------------+
void M1TimeClose()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL)!="XAUUSD") continue;
      if(PositionGetInteger(POSITION_MAGIC)!=20260525+1) continue;
      if(TimeCurrent()-(datetime)PositionGetInteger(POSITION_TIME)>=InpM1HoldMin*60)
         trade.PositionClose(t);
   }
}

//+------------------------------------------------------------------+
//| H1管理・エントリー                                                 |
//+------------------------------------------------------------------+
void H1Manage()
{
   if(!g_h1Open) return;
   if(TimeCurrent()-g_h1EntryTime<InpHoldHours*3600) return;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL)=="XAUUSD"&&
         PositionGetInteger(POSITION_MAGIC)==20260525)
         trade.PositionClose(t);
   }
   g_h1Open=false; g_alertActive=false;
}

void H1Entry(double score)
{
   if(g_h1Open||!DailyRiskOK()) return;
   double ask=SymbolInfoDouble("XAUUSD",SYMBOL_ASK);
   trade.SetExpertMagicNumber(20260525);
   trade.SetDeviationInPoints(20);
   if(trade.Buy(InpLotMain,"XAUUSD",ask,
      ask*(1.0-InpSL_Pct/100.0),ask*(1.0+InpTP_Pct/100.0),
      StringFormat("TendoH1 score=%.3f e=%s",score,g_eventId)))
   {g_h1Open=true;g_h1EntryTime=TimeCurrent();g_lastScore=score;}
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // 平常時ベースライン記録（最優先）
   BaselineSample();

   // イベント時tick記録
   SampleTick();

   // H1管理
   H1Manage();

   // M1クローズ・スキャルプ
   M1TimeClose();
   M1ScalpCheck();

   // アラートトリガー
   if(!g_alertActive)
   {
      bool triggered=false;
      if(InpManualTrigger){
         triggered=true; g_eventId="MANUAL"; g_lastAlertTime=TimeCurrent();
         RecordNeutrinoEvent("MANUAL",TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES),"GOLD");
      }
      if(!triggered&&InpAutoFetch) triggered=FetchIceCubeAlert();
      if(triggered){
         g_alertActive=true; g_alertTime=TimeCurrent();
         g_windowStart=TimeCurrent(); g_windowTicks=0; g_recordCount=0;
         double score=CalcCompositeScore();
         if(score>=InpScoreThreshold) H1Entry(score);
      }
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(20260525);
   g_dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStart=TimeCurrent();
   g_windowStart=TimeCurrent();

   Print("============================================");
   Print(" TendoEconomics EA v3.2 起動");
   Print(" Event + Baseline Recording Edition");
   Print(" Author : Yoshimitsu Katayama / TheYKHC Research");
   Print(" Paper  : DOI 10.5281/zenodo.20093286");
   Print("--------------------------------------------");
   Print(" DB記録: ",       InpDBRecord       ? "有効":"無効");
   Print(" Baseline記録: ", InpBaselineRecord ? "有効":"無効");
   Print(" Baseline開始時刻: 毎日 ",InpBaselineHour,"時（サーバー時間）");
   Print(" APIキー: ",StringLen(InpDBApiKey)>0?"設定済み":"★未設定★");
   Print("============================================");

   if(StringLen(InpDBApiKey)==0)
      Alert("TendoEconomics v3.2: InpDBApiKeyを設定してください！");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("[TendoEcon v3.2] 停止 reason=",reason,
         " イベント記録=",g_recordCount,"件",
         " Baseline記録=",g_baselineCount,"件",
         " 実測baseline密度=",DoubleToString(g_baselineDensity,3));
}
//+------------------------------------------------------------------+
