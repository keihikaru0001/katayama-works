//+------------------------------------------------------------------+
//| EA DB接続テスト — TendoEconomics DB Test                         |
//| MT5からBase44へ1件だけ送信して疎通確認する                         |
//+------------------------------------------------------------------+
#property strict

input string InpDBApiKey = "";  // ← ここにAPIキーを貼る

int OnInit()
{
   string endpoint = "https://app.base44.com/api/apps/69d570145faf332412ad4c73/entities/FxTickSnapshot";
   string headers  = "Content-Type: application/json\r\nx-api-key: " + InpDBApiKey + "\r\n";

   string body = "{\"event_id\":\"TEST_001\","
                 "\"symbol\":\"XAUUSD\","
                 "\"seconds_after_gcn\":0,"
                 "\"tick_density\":1.0,"
                 "\"bid_velocity\":0.0,"
                 "\"spread\":0.5,"
                 "\"volume\":1.0,"
                 "\"bid\":" + DoubleToString(SymbolInfoDouble("XAUUSD",SYMBOL_BID),2) + ","
                 "\"ask\":" + DoubleToString(SymbolInfoDouble("XAUUSD",SYMBOL_ASK),2) + ","
                 "\"anomaly_score\":0.0,"
                 "\"window\":\"TEST\","
                 "\"note\":\"MT5疎通テスト " + TimeToString(TimeCurrent()) + "\"}";

   char post[], result[];
   string resHeaders;
   StringToCharArray(body, post, 0, StringLen(body));

   int res = WebRequest("POST", endpoint, headers, 10000, post, result, resHeaders);

   if(res == 200 || res == 201)
   {
      Print("✓ DB送信成功! レスポンス: ", CharArrayToString(result));
      Alert("✓ Base44 DB接続OK！テストデータ送信成功");
   }
   else
   {
      Print("✗ DB送信失敗 HTTPコード=", res);
      Print("レスポンス: ", CharArrayToString(result));
      Alert("✗ DB送信失敗 コード=", res, " APIキーを確認してください");
   }

   return INIT_SUCCEEDED;
}

void OnTick() {}
//+------------------------------------------------------------------+
