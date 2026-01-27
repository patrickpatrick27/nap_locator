import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:googleapis/sheets/v4.dart' as sheets;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

class SheetService {
  static const String _spreadsheetId = '1x_IsBXD0Tky4lZwg9lrIgUVR7s_rbfnC0c2L9adOwdI';
  
  // Updated key to force a fresh fetch for OLT Port & EAC001
  static const String _cacheKey = 'lcp_data_multi_sheet_v3_olt_port_eac'; 

  // List of all tabs to fetch (Includes your new EAC001)
  static const List<String> _targetSheetNames = [
    "TGY001", "TGY002", "EAC001",
    "AFC001", "AMC001",
    "IDC001", "IDC002", "IDC003",
    "MGC001", "MRC001", "MRC002",
    "MZC001", "MZC002",
    "TMC002", "TNC001"
  ];

  /// Fetches fresh data from Google Sheets using Batch Get
  Future<List<dynamic>> fetchLcpData() async {
    try {
      print("🔐 Loading credentials...");
      final jsonString = await rootBundle.loadString('assets/credentials.json');
      final credentials = ServiceAccountCredentials.fromJson(jsonString);

      final client = await clientViaServiceAccount(credentials, [sheets.SheetsApi.spreadsheetsReadonlyScope]);
      final sheetsApi = sheets.SheetsApi(client);
      
      List<dynamic> allCombinedData = [];
      
      print("🚀 FAST MODE: Batch fetching ${_targetSheetNames.length} sheets in ONE call...");

      // Prepare ranges for all sheets at once
      List<String> ranges = _targetSheetNames.map((name) => '$name!A:AZ').toList();

      try {
        final batchResponse = await sheetsApi.spreadsheets.values.batchGet(
          _spreadsheetId, 
          ranges: ranges
        );

        if (batchResponse.valueRanges != null) {
          for (var i = 0; i < batchResponse.valueRanges!.length; i++) {
            var valueRange = batchResponse.valueRanges![i];
            
            // Identify which sheet this data belongs to
            String sheetName = _extractSheetNameFromRange(valueRange.range, i);

            if (valueRange.values != null && valueRange.values!.isNotEmpty) {
              List<dynamic> sheetData = _parseSheetData(valueRange.values!, sheetName);
              allCombinedData.addAll(sheetData);
              print("   ✅ Parsed $sheetName (${sheetData.length} items)");
            } else {
              print("   ⚠️ Sheet $sheetName was empty.");
            }
          }
        }
      } catch (e) {
        print("❌ Batch Fetch Error: $e");
        print("⚠️ Attempting fallback to cache...");
        client.close();
        return loadFromCache();
      }
      
      client.close();

      if (allCombinedData.isNotEmpty) {
        // Cache the combined data
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, jsonEncode(allCombinedData));
        print("🎉 DONE! Loaded ${allCombinedData.length} total items.");
        return allCombinedData;
      } else {
        return loadFromCache();
      }

    } catch (e) {
      print("❌ Critical Error: $e");
      return loadFromCache();
    }
  }

  String _extractSheetNameFromRange(String? rangeStr, int index) {
    if (rangeStr != null && rangeStr.contains('!')) {
      return rangeStr.split('!')[0].replaceAll("'", "");
    }
    if (index < _targetSheetNames.length) {
      return _targetSheetNames[index];
    }
    return "UnknownSheet";
  }

  /// Public method to load cached data immediately
  Future<List<dynamic>> loadFromCache() async {
    final prefs = await SharedPreferences.getInstance();
    String? cachedString = prefs.getString(_cacheKey);
    
    if (cachedString != null && cachedString.isNotEmpty) {
      print("📂 Loaded from local cache (Instant Load)");
      return jsonDecode(cachedString);
    }
    return []; 
  }

  // --- PARSER LOGIC ---
  List<dynamic> _parseSheetData(List<List<dynamic>> rawRows, String sheetOrigin) {
    if (rawRows.length < 3) return []; 

    Map<String, Map<String, dynamic>> lcpMap = {};
    
    List<dynamic> headerRow = rawRows[1]; 
    List<int> blockStarts = [];

    for (int i = 0; i < headerRow.length; i++) {
      String cell = headerRow[i].toString().toUpperCase().trim();
      if (cell == "OLT PORT") {
        blockStarts.add(i);
      }
    }

    if (blockStarts.isEmpty) blockStarts = [0, 15, 30]; 

    for (var i = 2; i < rawRows.length; i++) {
      List<dynamic> row = List.from(rawRows[i]);
      while (row.length < 60) row.add(""); 

      for (int k = 0; k < blockStarts.length; k++) {
        int startIdx = blockStarts[k];
        int oltNum = k + 1;
        try {
          _processBlock(row, startIdx, oltNum, lcpMap, sheetOrigin);
        } catch (e) {}
      }
    }

    var validLcps = lcpMap.values.where((lcp) => lcp['nps'].isNotEmpty).toList();
    validLcps.sort((a, b) => a['lcp_name'].toString().compareTo(b['lcp_name'].toString()));
    return validLcps;
  }

  void _processBlock(List<dynamic> row, int startIdx, int oltNum, Map<String, Map<String, dynamic>> lcpMap, String sheetOrigin) {
    if (row.length <= startIdx + 1) return;
    String lcpName = row[startIdx + 1].toString().trim();
    
    if (lcpName.isEmpty || 
        lcpName.toUpperCase().contains("VACANT") || 
        lcpName.toUpperCase().contains("LCP NAME") ||
        lcpName.toUpperCase() == "0") {
      return;
    }

    String siteNameFromRow = row[startIdx + 2].toString().trim();
    String finalSiteName = siteNameFromRow.isNotEmpty ? siteNameFromRow : sheetOrigin;
    String uniqueKey = "$lcpName-$sheetOrigin";

    if (!lcpMap.containsKey(uniqueKey)) {
      String val(int offset) {
        int target = startIdx + offset;
        if (target < row.length) return row[target].toString().trim();
        return "";
      }

      lcpMap[uniqueKey] = {
        'lcp_name': lcpName,
        'site_name': finalSiteName, 
        'olt_id': oltNum,
        'source_sheet': sheetOrigin,
        'details': {
          'OLT Port': val(0), // <--- ADDED: Captures "0/1/0" column
          'ODF': val(3),
          'ODF Port': val(4),
          'Date': val(5),
          'Distance': val(6),
          'Rack ID': val(7),
          'New ODF': val(8),
          'New Port': val(9),
        },
        'nps': []
      };
    }

    _addNpSafely(lcpMap[uniqueKey]!, "NP1-2", row, startIdx + 10);
    _addNpSafely(lcpMap[uniqueKey]!, "NP3-4", row, startIdx + 11);
    _addNpSafely(lcpMap[uniqueKey]!, "NP5-6", row, startIdx + 12);
    _addNpSafely(lcpMap[uniqueKey]!, "NP7-8", row, startIdx + 13);
  }

  void _addNpSafely(Map<String, dynamic> lcpObj, String npName, List<dynamic> row, int colIndex) {
    if (colIndex >= row.length) return;
    String rawValue = row[colIndex].toString();
    if (rawValue.trim().isEmpty || rawValue.toUpperCase().contains("N/A")) return;

    String spacedValue = rawValue.replaceAll(RegExp(r'[^0-9.,-]'), ' ');
    List<String> chunks = spacedValue.split(RegExp(r'[ ,]+'));
    
    double? lat, lng;
    for (String chunk in chunks) {
      if (chunk.isEmpty) continue;
      double? val = double.tryParse(chunk);
      if (val != null) {
        if (lat == null) lat = val;
        else if (lng == null) { lng = val; break; }
      }
    }

    if (lat != null && lng != null) {
      if (lat > 4 && lat < 22 && lng > 116 && lng < 128) {
        lcpObj['nps'].add({'name': npName, 'lat': lat, 'lng': lng});
      }
    }
  }
}