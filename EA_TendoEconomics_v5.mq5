//+------------------------------------------------------------------+
//| EA: TendoEconomics v5.0 — Total Signal Engine                    |
//|                                                                  |
//| Author  : Yoshimitsu Katayama                                    |
//|           ORCID: 0009-0006-2290-6593                             |
//|           TheYKHC Research / https://theykhc.com                |
//|                                                                  |
//| Theory  : V=N/D — Social Transmission Hypothesis                 |
//|           N=全指標シグナル数 / D=指標間矛盾数 / V=方向スコア        |
//| Paper   : DOI: 10.5281/zenodo.20093286                           |
//|                                                                  |
//| Mode    : 7カテゴリ指標を統合 → XAUUSDに集約                      |
//|           天体・貴金属・リスク・エネルギー・指数・新興国・労働意欲   |
//+------------------------------------------------------------------+

#property copyright "© 2026 TheYKHC Research / Yoshimitsu Katayama"
#property link      "https://theykhc.com"
#property version   "5.00"
#property description "TendoEconomics EA v5.0 — Total Signal Engine (XAUUSD)"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| 入力パラメータ                                                     |
//+------------------------------------------------------------------+
input group "=== エントリー設定 ==="
input double InpLot            = 0.05;      // ロット
input int    InpTP_Pips        = 200;       // TP（pips）
input int    InpSL_Pips        = 100;       // SL（pips）
input int    InpHoldHours      = 24;        // 最大保有時間
input double InpBuyThreshold   = 0.55;      // BUYシグナル閾値（0〜1）
input double InpSellThreshold  = 0.55;      // SELLシグナル閾値（0〜1）
input int    InpMaxTrades      = 1;         // 最大同時ポジション数
input int    InpSignalIntervalH= 4;         // シグナル再計算間隔（時間）

input group "=== 指標の重み ==="
input double InpW_Moon         = 0.10;      // ① 月齢
input double InpW_Biorhythm    = 0.08;      // ① バイオリズム
input double InpW_Silver       = 0.10;      // ② 銀
input double InpW_Platinum     = 0.10;      // ② プラチナ
input double InpW_GoldPattern  = 0.10;      // ② 金前日パターン
input double InpW_BTC          = 0.08;      // ③ BTC
input double InpW_AI           = 0.06;      // ③ AI&ROBOT
input double InpW_Wind         = 0.06;      // ④ 風力ETF
input double InpW_Solar        = 0.06;      // ④ 太陽光ETF
input double InpW_Nikkei       = 0.08;      // ⑤ 日経平均
input double InpW_USDJPY       = 0.06;      // ⑤ ドル円
input double InpW_China        = 0.06;      // ⑥ 中国株
input double InpW_Korea        = 0.04;      // ⑥ 韓国株
input double InpW_UK           = 0.02;      // ⑦ 英国労働意欲（GBP）

input group "=== 月齢・バイオリズム ==="
input int    InpBirthYear      = 1970;      // 生年（バイオリズム用）
input int    InpBirthMonth     = 8;
input int    InpBirthDay       = 12;

input group "=== IceCube GOLDイベント ==="
input bool   InpGoldEventBoost = true;      // GOLDイベント時スコアブースト
input double InpGoldBoostVal   = 0.20;      // ブースト値
input bool   InpAutoFetch      = true;
input int    InpFetchIntervalH = 6;
input int    InpCooldownHours  = 168;

input group "=== DB記録 ==="
input bool   InpDBRecord       = true;
input string InpDBEndpoint     = "https://app.base44.com/api/apps/69d570145faf332412ad4c73/entities";
input string InpDBApiKey       = "";

input group "=== リスク管理 ==="
input double InpMaxDailyLoss   = 2.0;       // 1日最大損失（%）

//+------------------------------------------------------------------+
//| グローバル変数                                                     |
//+------------------------------------------------------------------+
CTrade trade;

datetime g_lastSignalTime  = 0;
datetime g_lastFetchTime   = 0;
datetime g_lastAlertTime   = 0;
bool     g_goldEvent       = false;
string   g_eventId         = "";

double   g_lastBuyScore    = 0;
double   g_lastSellScore   = 0;
string   g_lastReport      = "";

double   g_dayStartBalance = 0;
datetime g_dayStart        = 0;

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
   return (res==200||res==201);
}

double PipsToPrice(int pips)
{
   return pips * SymbolInfoDouble("XAUUSD", SYMBOL_POINT) * 10.0;
}

bool DailyRiskOK()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));
   if(g_dayStart != today){ g_dayStart = today; g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE); }
   double loss = (g_dayStartBalance - AccountInfoDouble(ACCOUNT_EQUITY)) / g_dayStartBalance * 100.0;
   return (loss < InpMaxDailyLoss);
}

int CountPositions()
{
   int cnt = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == "XAUUSD" &&
         PositionGetInteger(POSITION_MAGIC) == 20260525+50) cnt++;
   }
   return cnt;
}

void CloseOldPositions()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) != "XAUUSD") continue;
      if(PositionGetInteger(POSITION_MAGIC) != 20260525+50) continue;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(TimeCurrent() - openTime >= InpHoldHours * 3600)
      {
         trade.PositionClose(ticket);
         Print("[v5] 時間クローズ ticket=", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| ① 月齢シグナル                                                    |
//| 新月前後→強気 / 満月前後→弱気 / それ以外→中立                       |
//+------------------------------------------------------------------+
double MoonSignal()
{
   // 月齢計算（簡易版）
   // 基準：2000年1月6日 = 新月（Julian Day 2451549.5）
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   double jd = 367.0*dt.year
             - (int)(7*(dt.year+(int)((dt.mon+9)/12))/4)
             + (int)(275*dt.mon/9)
             + dt.day + 1721013.5
             + dt.hour/24.0;
   double daysSinceNew = MathMod(jd - 2451549.5, 29.53);
   if(daysSinceNew < 0) daysSinceNew += 29.53;

   // 新月前後3日（買い圧力）
   if(daysSinceNew <= 3 || daysSinceNew >= 26.53)
      return 1.0;   // 強気

   // 満月前後3日（売り圧力・利確）
   if(daysSinceNew >= 11.77 && daysSinceNew <= 17.77)
      return -1.0;  // 弱気

   // 上弦（月が膨らむ）→ やや強気
   if(daysSinceNew > 3 && daysSinceNew < 11.77)
      return 0.5;

   // 下弦（月が欠ける）→ やや弱気
   return -0.5;
}

//+------------------------------------------------------------------+
//| ① バイオリズムシグナル                                            |
//| 身体・感情・知性の3波を合成。全波プラス→強気                        |
//+------------------------------------------------------------------+
double BiorhythmSignal()
{
   MqlDateTime bd;
   bd.year = InpBirthYear; bd.mon = InpBirthMonth; bd.day = InpBirthDay;
   bd.hour = 0; bd.min = 0; bd.sec = 0;
   datetime birthDate = StructToTime(bd);
   double days = (double)(TimeCurrent() - birthDate) / 86400.0;

   double phys     = MathSin(2 * M_PI * days / 23.0);  // 身体
   double emotion  = MathSin(2 * M_PI * days / 28.0);  // 感情
   double intellect= MathSin(2 * M_PI * days / 33.0);  // 知性

   double avg = (phys + emotion + intellect) / 3.0;

   if(avg >  0.5) return  1.0;
   if(avg < -0.5) return -1.0;
   return avg; // -0.5〜0.5
}

//+------------------------------------------------------------------+
//| ② 貴金属シグナル（銀・プラチナ・金前日パターン）                   |
//+------------------------------------------------------------------+
double MetalSignal(string symbol)
{
   double c0 = iClose(symbol, PERIOD_H4, 0);
   double c3 = iClose(symbol, PERIOD_H4, 3);
   if(c0==0 || c3==0) return 0;
   double chg = (c0 - c3) / c3;
   if(chg >  0.005) return  1.0;
   if(chg < -0.005) return -1.0;
   return 0;
}

double GoldPatternSignal()
{
   // 前日の終値→始値の方向
   double yesterday_close = iClose("XAUUSD", PERIOD_D1, 1);
   double yesterday_open  = iOpen("XAUUSD",  PERIOD_D1, 1);
   double today_open      = iOpen("XAUUSD",  PERIOD_D1, 0);
   if(yesterday_close==0 || yesterday_open==0) return 0;

   double prevDir = yesterday_close - yesterday_open;
   double prevRange = MathAbs(iHigh("XAUUSD",PERIOD_D1,1) - iLow("XAUUSD",PERIOD_D1,1));

   // 前日大陽線→今日も続伸しやすい
   if(prevDir > prevRange * 0.6)  return  1.0;
   if(prevDir < -prevRange * 0.6) return -1.0;

   // 今日の始値が前日終値より上→強気
   if(today_open > yesterday_close) return  0.5;
   if(today_open < yesterday_close) return -0.5;
   return 0;
}

//+------------------------------------------------------------------+
//| ③ リスク資産シグナル（BTC・AI/ROBOT）                             |
//+------------------------------------------------------------------+
double RiskAssetSignal(string symbol)
{
   double c0 = iClose(symbol, PERIOD_H4, 0);
   double c6 = iClose(symbol, PERIOD_H4, 6);
   if(c0==0 || c6==0) return 0;
   double chg = (c0 - c6) / c6;
   if(chg >  0.01) return  1.0;
   if(chg < -0.01) return -1.0;
   return chg * 50; // 微小変動も反映
}

//+------------------------------------------------------------------+
//| ④ エネルギーシグナル（風力・太陽光ETF）                            |
//| MT5にない場合は代替としてOIL・US500を使用                          |
//+------------------------------------------------------------------+
double EnergySignal(string symbol, string fallback)
{
   double c0 = iClose(symbol, PERIOD_H4, 0);
   if(c0 == 0) c0 = iClose(fallback, PERIOD_H4, 0);
   double c6 = iClose(symbol, PERIOD_H4, 6);
   if(c6 == 0) c6 = iClose(fallback, PERIOD_H4, 6);
   if(c0==0 || c6==0) return 0;
   double chg = (c0 - c6) / c6;
   if(chg >  0.005) return  1.0;
   if(chg < -0.005) return -1.0;
   return 0;
}

//+------------------------------------------------------------------+
//| ⑤ 主要指数シグナル（日経・ドル円）                                 |
//+------------------------------------------------------------------+
double IndexSignal(string symbol, bool invertForGold)
{
   double c0 = iClose(symbol, PERIOD_H4, 0);
   double c3 = iClose(symbol, PERIOD_H4, 3);
   if(c0==0 || c3==0) return 0;
   double chg = (c0 - c3) / c3;
   double sig = 0;
   if(chg >  0.003) sig =  1.0;
   else if(chg < -0.003) sig = -1.0;

   // ドル円上昇→ドル高→金に逆風（反転）
   if(invertForGold) sig = -sig;
   return sig;
}

//+------------------------------------------------------------------+
//| ⑥ 新興国シグナル（中国・韓国）                                    |
//+------------------------------------------------------------------+
double EmergingSignal(string symbol)
{
   double c0 = iClose(symbol, PERIOD_D1, 0);
   double c1 = iClose(symbol, PERIOD_D1, 1);
   if(c0==0 || c1==0) return 0;
   double chg = (c0 - c1) / c1;
   if(chg >  0.005) return  1.0;
   if(chg < -0.005) return -1.0;
   return 0;
}

//+------------------------------------------------------------------+
//| ⑦ 英国労働意欲シグナル（GBP強弱で代替）                           |
//+------------------------------------------------------------------+
double UKLaborSignal()
{
   double c0 = iClose("GBPUSD", PERIOD_H4, 0);
   double c6 = iClose("GBPUSD", PERIOD_H4, 6);
   if(c0==0 || c6==0) return 0;
   double chg = (c0 - c6) / c6;
   // GBP強→リスクオン→金に中立〜やや弱気
   if(chg >  0.003) return -0.5;
   if(chg < -0.003) return  0.5;
   return 0;
}

//+------------------------------------------------------------------+
//| GCN取得                                                           |
//+------------------------------------------------------------------+
bool FetchIceCubeAlert()
{
   if(TimeCurrent()-g_lastAlertTime < InpCooldownHours*3600) return false;
   if(TimeCurrent()-g_lastFetchTime < InpFetchIntervalH*3600) return false;
   g_lastFetchTime = TimeCurrent();

   string headers = "User-Agent: TendoEconomics-EA/5.0\r\n";
   char post[], result[]; string resH;
   int res = WebRequest("GET","https://gcn.nasa.gov/circulars.atom",
                        headers, 5000, post, result, resH);
   if(res!=200 || ArraySize(result)==0) return false;

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
         bool hasIC = (StringFind(body,"IceCube")>=0||StringFind(body,"icecube")>=0);
         bool hasGO = (StringFind(body,"GOLD")>=0||StringFind(body,"astrophysical neutrino")>=0);
         if(hasIC && hasGO)
         {
            g_eventId       = idStr;
            g_lastAlertTime = TimeCurrent();
            g_goldEvent     = true;
            Print("[v5] ★★★ GOLDイベント! Circular=", idStr);
            return true;
         }
      }
      pos=idx+1; checked++;
   }
   return false;
}

//+------------------------------------------------------------------+
//| メインシグナル計算（V=N/D）                                        |
//+------------------------------------------------------------------+
void CalcSignal(double &buyScore, double &sellScore, string &report)
{
   double totalWeight = 0;
   double bullSum = 0;  // 強気合計
   double bearSum = 0;  // 弱気合計
   int    nSignals = 0; // シグナル数（N）
   int    conflicts= 0; // 矛盾数（D）
   string rep = "";

   // --- ① 天体・自然リズム ---
   double moonSig = MoonSignal();
   double bioSig  = BiorhythmSignal();

   if(moonSig > 0) { bullSum += moonSig * InpW_Moon; nSignals++; }
   else if(moonSig < 0) { bearSum += MathAbs(moonSig) * InpW_Moon; nSignals++; }
   totalWeight += InpW_Moon;

   if(bioSig > 0) { bullSum += bioSig * InpW_Biorhythm; nSignals++; }
   else if(bioSig < 0) { bearSum += MathAbs(bioSig) * InpW_Biorhythm; nSignals++; }
   totalWeight += InpW_Biorhythm;

   rep += StringFormat("Moon=%.1f Bio=%.2f | ", moonSig, bioSig);

   // --- ② 貴金属 ---
   double agSig  = MetalSignal("XAGUSD");
   double ptSig  = MetalSignal("XPTUSD");
   double gpSig  = GoldPatternSignal();

   if(agSig > 0) bullSum += agSig * InpW_Silver;
   else if(agSig < 0) bearSum += MathAbs(agSig) * InpW_Silver;
   if(agSig != 0) nSignals++;
   totalWeight += InpW_Silver;

   if(ptSig > 0) bullSum += ptSig * InpW_Platinum;
   else if(ptSig < 0) bearSum += MathAbs(ptSig) * InpW_Platinum;
   if(ptSig != 0) nSignals++;
   totalWeight += InpW_Platinum;

   if(gpSig > 0) bullSum += gpSig * InpW_GoldPattern;
   else if(gpSig < 0) bearSum += MathAbs(gpSig) * InpW_GoldPattern;
   if(gpSig != 0) nSignals++;
   totalWeight += InpW_GoldPattern;

   rep += StringFormat("Ag=%.1f Pt=%.1f GP=%.1f | ", agSig, ptSig, gpSig);

   // --- ③ リスク資産 ---
   double btcSig = RiskAssetSignal("BTCUSD");
   double aiSig  = RiskAssetSignal("US500"); // AI/ROBOT代替

   if(btcSig > 0) bullSum += btcSig * InpW_BTC;
   else if(btcSig < 0) bearSum += MathAbs(btcSig) * InpW_BTC;
   if(btcSig != 0) nSignals++;
   totalWeight += InpW_BTC;

   if(aiSig > 0) bullSum += aiSig * InpW_AI;
   else if(aiSig < 0) bearSum += MathAbs(aiSig) * InpW_AI;
   if(aiSig != 0) nSignals++;
   totalWeight += InpW_AI;

   rep += StringFormat("BTC=%.1f AI=%.1f | ", btcSig, aiSig);

   // --- ④ エネルギー ---
   double windSig  = EnergySignal("ICLN",  "UKOIL");
   double solarSig = EnergySignal("TAN",   "US500");

   if(windSig > 0) bullSum += windSig * InpW_Wind;
   else if(windSig < 0) bearSum += MathAbs(windSig) * InpW_Wind;
   if(windSig != 0) nSignals++;
   totalWeight += InpW_Wind;

   if(solarSig > 0) bullSum += solarSig * InpW_Solar;
   else if(solarSig < 0) bearSum += MathAbs(solarSig) * InpW_Solar;
   if(solarSig != 0) nSignals++;
   totalWeight += InpW_Solar;

   rep += StringFormat("Wind=%.1f Solar=%.1f | ", windSig, solarSig);

   // --- ⑤ 主要指数 ---
   double nkSig  = IndexSignal("JP225",  false);
   double djSig  = IndexSignal("USDJPY", true); // ドル円は反転

   if(nkSig > 0) bullSum += nkSig * InpW_Nikkei;
   else if(nkSig < 0) bearSum += MathAbs(nkSig) * InpW_Nikkei;
   if(nkSig != 0) nSignals++;
   totalWeight += InpW_Nikkei;

   if(djSig > 0) bullSum += djSig * InpW_USDJPY;
   else if(djSig < 0) bearSum += MathAbs(djSig) * InpW_USDJPY;
   if(djSig != 0) nSignals++;
   totalWeight += InpW_USDJPY;

   rep += StringFormat("NK=%.1f USDJPY=%.1f | ", nkSig, djSig);

   // --- ⑥ 新興国 ---
   double cnSig = EmergingSignal("CHINAH");
   double krSig = EmergingSignal("USDKRW"); // KRW強→リスクオン→やや金弱気

   if(cnSig > 0) bullSum += cnSig * InpW_China;
   else if(cnSig < 0) bearSum += MathAbs(cnSig) * InpW_China;
   if(cnSig != 0) nSignals++;
   totalWeight += InpW_China;

   if(krSig != 0) nSignals++;
   totalWeight += InpW_Korea;

   rep += StringFormat("CN=%.1f KR=%.1f | ", cnSig, krSig);

   // --- ⑦ 英国労働意欲 ---
   double ukSig = UKLaborSignal();

   if(ukSig > 0) bullSum += ukSig * InpW_UK;
   else if(ukSig < 0) bearSum += MathAbs(ukSig) * InpW_UK;
   if(ukSig != 0) nSignals++;
   totalWeight += InpW_UK;

   rep += StringFormat("UK=%.1f", ukSig);

   // --- V=N/D スコア計算 ---
   // D = bullSum と bearSum が拮抗する度合い（矛盾）
   double minVal = MathMin(bullSum, bearSum);
   double D = (totalWeight > 0) ? (minVal / totalWeight) + 1.0 : 1.0;
   double N_bull = bullSum;
   double N_bear = bearSum;

   buyScore  = (totalWeight > 0) ? (N_bull / D) / totalWeight : 0;
   sellScore = (totalWeight > 0) ? (N_bear / D) / totalWeight : 0;

   // GOLDイベントブースト
   if(g_goldEvent && InpGoldEventBoost)
   {
      buyScore  += InpGoldBoostVal;
      sellScore += InpGoldBoostVal * 0.5;
      rep += " [GOLD_BOOST]";
   }

   report = StringFormat("[v5 Signal] BUY=%.3f SELL=%.3f N=%d D=%.3f | %s",
                         buyScore, sellScore, nSignals, D, rep);
}

//+------------------------------------------------------------------+
//| エントリー                                                         |
//+------------------------------------------------------------------+
void TryEntry(double buyScore, double sellScore)
{
   if(!DailyRiskOK()) return;
   if(CountPositions() >= InpMaxTrades) return;

   trade.SetExpertMagicNumber(20260525+50);
   trade.SetDeviationInPoints(30);

   if(buyScore >= InpBuyThreshold && buyScore > sellScore)
   {
      double ask = SymbolInfoDouble("XAUUSD", SYMBOL_ASK);
      double sl  = ask - PipsToPrice(InpSL_Pips);
      double tp  = ask + PipsToPrice(InpTP_Pips);
      if(trade.Buy(InpLot, "XAUUSD", ask, sl, tp,
         StringFormat("v5_BUY B=%.3f S=%.3f", buyScore, sellScore)))
         Print("[v5] BUY エントリー ask=", ask);
   }
   else if(sellScore >= InpSellThreshold && sellScore > buyScore)
   {
      double bid = SymbolInfoDouble("XAUUSD", SYMBOL_BID);
      double sl  = bid + PipsToPrice(InpSL_Pips);
      double tp  = bid - PipsToPrice(InpTP_Pips);
      if(trade.Sell(InpLot, "XAUUSD", bid, sl, tp,
         StringFormat("v5_SELL B=%.3f S=%.3f", buyScore, sellScore)))
         Print("[v5] SELL エントリー bid=", bid);
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== TendoEconomics v5.0 Total Signal Engine 起動 ===");
   Print("指標: 月齢/バイオリズム/銀/プラチナ/金パターン/BTC/AI/風力/太陽光/日経/USDJPY/中国/韓国/英国");
   Print("集約先: XAUUSD");
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_lastFetchTime   = TimeCurrent() - InpFetchIntervalH * 3600;
   EventSetTimer(3600); // 1時間ごとにGCN確認
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("=== TendoEconomics v5.0 停止 ===");
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // 時間クローズ
   CloseOldPositions();

   // シグナル再計算（InpSignalIntervalH時間ごと）
   if(TimeCurrent() - g_lastSignalTime < InpSignalIntervalH * 3600) return;
   g_lastSignalTime = TimeCurrent();

   double buyScore, sellScore;
   string report;
   CalcSignal(buyScore, sellScore, report);

   g_lastBuyScore  = buyScore;
   g_lastSellScore = sellScore;
   g_lastReport    = report;

   Print(report);

   // エントリー試行
   TryEntry(buyScore, sellScore);
}

//+------------------------------------------------------------------+
//| OnTimer（GCN監視）                                                 |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(InpAutoFetch) FetchIceCubeAlert();
}

//+------------------------------------------------------------------+
