using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace StockDashboard
{
    public sealed class ProfitResult
    {
        public decimal Amount { get; set; }
        public decimal? Percent { get; set; }
    }

    public sealed class FeeEstimate
    {
        public decimal PurchaseAmount { get; set; }
        public decimal CommissionRate { get; set; }
        public decimal Commission { get; set; }
        public decimal TransferFee { get; set; }
        public decimal TotalFees { get; set; }
        public decimal TotalCost { get; set; }
    }

    public sealed class TrackingRecord
    {
        public decimal? CostPrice { get; set; }
        public long? Quantity { get; set; }
        public decimal? TotalCost { get; set; }
        public decimal? PerShareCost { get; set; }
        public decimal? PurchaseAmount { get; set; }
        public decimal? CommissionRate { get; set; }
        public decimal? Upper { get; set; }
        public decimal? Lower { get; set; }
        public bool UpperTriggered { get; set; }
        public bool LowerTriggered { get; set; }
        public DateTimeOffset? ArmedAt { get; set; }
        public bool HasPosition { get { return Quantity.HasValue && (CostPrice.HasValue || TotalCost.HasValue || PerShareCost.HasValue); } }
        public bool HasAlerts { get { return Upper.HasValue || Lower.HasValue; } }
        public bool HasTriggeredAlerts { get { return UpperTriggered || LowerTriggered; } }
        public bool IsEstimated { get { return PurchaseAmount.HasValue; } }
        public decimal? EffectiveCost
        {
            get {
                if (!Quantity.HasValue || Quantity <= 0) return null;
                try {
                    if (PerShareCost.HasValue) {
                        if (TotalCost.HasValue || PurchaseAmount.HasValue || CommissionRate.HasValue) return null;
                        decimal total = checked(PerShareCost.Value * Quantity.Value);
                        if (total / Quantity.Value != PerShareCost.Value) return null;
                        return total;
                    }
                    if (TotalCost.HasValue) return TotalCost > 0 ? TotalCost : null;
                    if (CostPrice.HasValue && CostPrice > 0) return checked(CostPrice.Value * Quantity.Value);
                } catch (OverflowException) { }
                return null;
            }
        }

        public void Validate()
        {
            if (Quantity.HasValue && Quantity <= 0) throw TrackingService.Input("持仓股数请输入正整数，单位为股。");
            bool hasCost = CostPrice.HasValue || TotalCost.HasValue || PerShareCost.HasValue;
            if (hasCost != Quantity.HasValue) throw TrackingService.Input("成本与持仓股数需同时填写，或同时留空。");
            if (PerShareCost.HasValue) {
                TrackingService.Exact(TrackingService.Raw(PerShareCost.Value), 8, true, "每股成本");
                if (TotalCost.HasValue || PurchaseAmount.HasValue || CommissionRate.HasValue) throw TrackingService.Input("每股成本不能与买入金额、含费总成本同时保存。");
                CostPrice = PerShareCost;
            } else if (TotalCost.HasValue) {
                TrackingService.Exact(TrackingService.Raw(TotalCost.Value), 2, false, "含费总成本");
                if (Quantity.HasValue) CostPrice = TotalCost.Value / Quantity.Value;
            } else if (CostPrice.HasValue && CostPrice <= 0) throw TrackingService.Input("成本价需大于0。");
            if (PurchaseAmount.HasValue) {
                TrackingService.Exact(TrackingService.Raw(PurchaseAmount.Value), 2, false, "买入金额");
                if (!TotalCost.HasValue || !Quantity.HasValue || PurchaseAmount > TotalCost) throw TrackingService.Input("买入金额需和总成本、股数配对，且不能大于总成本。");
            }
            if (CommissionRate.HasValue && (!PurchaseAmount.HasValue || CommissionRate <= 0 || CommissionRate > 30))
                throw TrackingService.Input("预估佣金需与成交金额一起保存，费率应大于0、不超过万分之30。");
            if (HasPosition && !EffectiveCost.HasValue) throw TrackingService.Input("持仓成本乘股数过大或无法精确保存，请检查输入。");
            if (Upper.HasValue && Upper <= 0 || Lower.HasValue && Lower <= 0) throw TrackingService.Input("提醒价格需大于0。");
            if (Upper.HasValue && Lower.HasValue && Lower >= Upper) throw TrackingService.Input("下方提醒价需小于上方提醒价。");
            if (!Upper.HasValue) UpperTriggered = false;
            if (!Lower.HasValue) LowerTriggered = false;
            if (!HasAlerts) ArmedAt = null;
        }

        public ProfitResult Profit(decimal price)
        {
            if (price <= 0 || !HasPosition || !EffectiveCost.HasValue) return null;
            try {
                decimal cost = EffectiveCost.Value;
                decimal unrounded = checked(price * Quantity.Value - cost);
                return new ProfitResult { Amount = TrackingService.Cents(unrounded), Percent = cost > 0 ? (decimal?)(unrounded / cost * 100m) : null };
            } catch (OverflowException) { return null; }
        }

        public List<string> TakeAlerts(decimal price, DateTimeOffset source, DateTimeOffset now, bool auction)
        {
            List<string> messages = new List<string>();
            double age = (now - source).TotalSeconds;
            if (auction || price <= 0 || age < -5 || age > 30 || ArmedAt.HasValue && source < ArmedAt.Value) return messages;
            if (Upper.HasValue && Upper > 0 && !UpperTriggered && price >= Upper) {
                UpperTriggered = true;
                messages.Add("升至" + TrackingService.Money(price, false) + "，上方提醒价" + TrackingService.Money(Upper.Value, false) + "。");
            }
            if (Lower.HasValue && Lower > 0 && !LowerTriggered && price <= Lower) {
                LowerTriggered = true;
                messages.Add("跌至" + TrackingService.Money(price, false) + "，下方提醒价" + TrackingService.Money(Lower.Value, false) + "。");
            }
            return messages;
        }

        public void Rearm(DateTimeOffset now)
        {
            UpperTriggered = false;
            LowerTriggered = false;
            ArmedAt = HasAlerts ? (DateTimeOffset?)now : null;
        }
    }

    public static class TrackingService
    {
        static readonly CultureInfo Invariant = CultureInfo.InvariantCulture;
        internal static ArgumentException Input(string message) { return new ArgumentException(message); }
        internal static string Raw(decimal value) { return value.ToString("0.############################", Invariant); }
        internal static decimal Cents(decimal value) { return decimal.Round(value, 2, MidpointRounding.AwayFromZero); }
        public static string Money(decimal value, bool signed)
        {
            decimal rounded = Cents(value);
            return (signed && rounded >= 0 ? "+" : "") + rounded.ToString("0.00", Invariant);
        }

        internal static decimal Exact(string text, int? fractionLimit, bool signed, string label)
        {
            string valueText = (text ?? "").Trim();
            string count = fractionLimit.HasValue ? "{1," + fractionLimit.Value + "}" : "+";
            string pattern = "^" + (signed ? "-?" : "") + "(?:[0-9]+(?:\\.[0-9]" + count + ")?|\\.[0-9]" + count + ")$";
            decimal value;
            if (!Regex.IsMatch(valueText, pattern) || !decimal.TryParse(valueText, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, Invariant, out value) || !signed && value <= 0)
                throw Input(label + "请输入有效十进制数" + (signed ? "，最多8位小数，可为0或负数。" : "，须大于0，不支持科学记数法。"));
            string magnitude = valueText.TrimStart('-');
            string[] parts = magnitude.Split('.');
            string integer = parts[0].TrimStart('0');
            string fraction = parts.Length > 1 ? parts[1].TrimEnd('0') : "";
            string canonical = (value < 0 ? "-" : "") + (integer.Length == 0 ? "0" : integer) + (fraction.Length == 0 ? "" : "." + fraction);
            if (Raw(value) != canonical) throw Input(label + "超出可精确保存的范围，请检查输入。");
            return value;
        }

        static decimal? Threshold(string text, string label)
        {
            return String.IsNullOrWhiteSpace(text) ? (decimal?)null : Exact(text, null, false, label);
        }

        public static FeeEstimate EstimateFees(string symbolId, string amount, string rate)
        {
            decimal purchase = Exact(amount, 2, false, "买入金额（最多2位小数）");
            decimal commissionRate = Exact(rate, null, false, "佣金万分比");
            if (commissionRate > 30) throw Input("佣金费率不能超过万分之30。");
            try {
                decimal product = checked(purchase * commissionRate);
                if (product / commissionRate != purchase) throw Input("金额或费率无法精确计算，请检查输入。");
                decimal commission = Cents(Math.Max(product / 10000m, 5m));
                decimal transfer = symbolId != null && symbolId.StartsWith("sh", StringComparison.OrdinalIgnoreCase) ? Cents(purchase / 100000m) : 0m;
                decimal fees = checked(commission + transfer);
                decimal total = checked(purchase + fees);
                if (total - purchase != fees) throw Input("总成本过大，无法精确保存到分。");
                return new FeeEstimate { PurchaseAmount = purchase, CommissionRate = commissionRate, Commission = commission, TransferFee = transfer, TotalFees = fees, TotalCost = total };
            } catch (OverflowException) { throw Input("金额或费率过大，无法精确计算费用。"); }
        }

        public static TrackingRecord AlertStateFromRaw(Dictionary<string, string> raw)
        {
            TrackingRecord record = new TrackingRecord();
            if (raw == null) return record;
            string value;
            if (raw.TryGetValue("Upper", out value)) {
                try { record.Upper = Threshold(value, "上方提醒价"); } catch (ArgumentException) { }
            }
            if (raw.TryGetValue("Lower", out value)) {
                try { record.Lower = Threshold(value, "下方提醒价"); } catch (ArgumentException) { }
            }
            bool triggered;
            record.UpperTriggered = record.Upper.HasValue && raw.TryGetValue("UpperTriggered", out value) && bool.TryParse(value, out triggered) && triggered;
            record.LowerTriggered = record.Lower.HasValue && raw.TryGetValue("LowerTriggered", out value) && bool.TryParse(value, out triggered) && triggered;
            DateTimeOffset armed;
            if (record.HasAlerts && raw.TryGetValue("ArmedAt", out value)
                && DateTimeOffset.TryParseExact(value, "o", Invariant, DateTimeStyles.None, out armed)) record.ArmedAt = armed;
            // This is prior state only: Build validates the edited threshold relationship and the new position.
            return record;
        }

        public static TrackingRecord Build(string symbolId, string mode, string amount, string quantity, string rate,
                                           string upper, string lower, TrackingRecord prior, DateTimeOffset now)
        {
            return Build(symbolId, mode, amount, quantity, rate, upper, lower, prior, now, null);
        }

        // The optional baseline distinguishes an explicit rate edit on older records with no historical rate.
        public static TrackingRecord Build(string symbolId, string mode, string amount, string quantity, string rate,
                                           string upper, string lower, TrackingRecord prior, DateTimeOffset now, string initialDefaultRate)
        {
            if (mode == "买入金额") mode = "purchase";
            if (mode == "含费总成本") mode = "total";
            if (mode == "每股成本") mode = "perShare";
            if (mode != "purchase" && mode != "total" && mode != "perShare") throw Input("请选择持仓输入方式。");
            amount = (amount ?? "").Trim(); quantity = (quantity ?? "").Trim(); rate = (rate ?? "").Trim();
            TrackingRecord record = new TrackingRecord();
            if (quantity.Length != 0) {
                long shares;
                if (!Regex.IsMatch(quantity, "^[0-9]+$") || !long.TryParse(quantity, NumberStyles.None, Invariant, out shares) || shares <= 0)
                    throw Input("持仓股数请输入正整数，单位为股。");
                record.Quantity = shares;
            }
            bool preserve = prior != null && prior.HasPosition && mode == "purchase" && quantity == prior.Quantity.Value.ToString(Invariant)
                && amount == (prior.PurchaseAmount.HasValue ? Raw(prior.PurchaseAmount.Value) : "")
                && (!prior.PurchaseAmount.HasValue || prior.CommissionRate.HasValue && rate == Raw(prior.CommissionRate.Value)
                    || !prior.CommissionRate.HasValue && (initialDefaultRate == null || rate == initialDefaultRate.Trim()));
            if (preserve) {
                prior.Validate();
                record.CostPrice = prior.CostPrice; record.TotalCost = prior.TotalCost; record.PerShareCost = prior.PerShareCost;
                record.PurchaseAmount = prior.PurchaseAmount; record.CommissionRate = prior.CommissionRate;
            } else if (amount.Length != 0) {
                if (mode == "perShare") record.PerShareCost = Exact(amount, 8, true, "每股成本");
                else if (mode == "total") record.TotalCost = Exact(amount, 2, false, "含费总成本（最多2位小数）");
                else {
                    FeeEstimate fees = EstimateFees(symbolId, amount, rate);
                    record.TotalCost = fees.TotalCost; record.PurchaseAmount = fees.PurchaseAmount; record.CommissionRate = fees.CommissionRate;
                }
            }
            record.Upper = Threshold(upper, "上方提醒价");
            record.Lower = Threshold(lower, "下方提醒价");
            record.UpperTriggered = record.Upper.HasValue && prior != null && record.Upper == prior.Upper && prior.UpperTriggered;
            record.LowerTriggered = record.Lower.HasValue && prior != null && record.Lower == prior.Lower && prior.LowerTriggered;
            bool changed = prior == null || record.Upper != prior.Upper || record.Lower != prior.Lower;
            record.ArmedAt = record.HasAlerts ? (changed ? now : prior.ArmedAt ?? now) : (DateTimeOffset?)null;
            record.Validate();
            return record;
        }
    }

    public sealed class AppSettings
    {
        public List<string> Symbols { get; set; }
        public Dictionary<string, TrackingRecord> Tracking { get; set; }
        public double Transparency { get; set; }
        public bool Pinned { get; set; }
        public bool AutoHide { get; set; }
        public double Left { get; set; }
        public double Top { get; set; }
        public string CommissionRate { get; set; }
        public bool StartWithWindows { get; set; }
        public Dictionary<string, string> InvalidTracking { get; private set; }
        public bool HasInvalidPositions { get; internal set; }
        internal Dictionary<string, object> RejectedTracking = new Dictionary<string, object>();
        internal Dictionary<string, string> RejectedTrackingJson = new Dictionary<string, string>();
        internal bool WholeTrackingCorrupt;

        public AppSettings()
        {
            Symbols = new List<string>(); Tracking = new Dictionary<string, TrackingRecord>();
            InvalidTracking = new Dictionary<string, string>();
            Transparency = 30; AutoHide = true; Left = double.NaN; Top = double.NaN; CommissionRate = "2.5";
        }
    }

    public sealed class SettingsStore
    {
        readonly string path;
        readonly JavaScriptSerializer serializer = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024, RecursionLimit = 64 };
        AppSettings currentSettings;
        bool originalBackupFailed;
        public string Notice { get; private set; }
        public SettingsStore(string path) { this.path = Path.GetFullPath(path); }

        public AppSettings Load()
        {
            AppSettings settings = new AppSettings(); Notice = null; originalBackupFailed = false;
            if (!File.Exists(path)) { currentSettings = settings; return settings; }
            try {
                string source = File.ReadAllText(path, Encoding.UTF8);
                Dictionary<string, object> document = serializer.DeserializeObject(source) as Dictionary<string, object>;
                if (document == null) throw new FormatException("设置必须为JSON对象。");
                Dictionary<string, string> rawDocument = JsonFields(source);
                object value;
                if (document.TryGetValue("Symbols", out value)) {
                    object[] values = value as object[];
                    if (values == null) throw new FormatException("自选列表类型不正确。");
                    foreach (object item in values) {
                        string id = item as string;
                        if (id != null && Regex.IsMatch(id, "^(sh|sz|bj)[0-9]{6}$") && !settings.Symbols.Contains(id) && settings.Symbols.Count < 20) settings.Symbols.Add(id);
                    }
                }
                settings.Transparency = Math.Max(0, Math.Min(100, ReadDouble(document, "Transparency", 30)));
                settings.Left = ReadDouble(document, "Left", double.NaN); settings.Top = ReadDouble(document, "Top", double.NaN);
                settings.Pinned = ReadBool(document, "Pinned", false); settings.AutoHide = ReadBool(document, "AutoHide", true);
                settings.StartWithWindows = ReadBool(document, "StartWithWindows", false);
                if (document.TryGetValue("CommissionRate", out value) && value is string) {
                    try { decimal rate = TrackingService.Exact((string)value, null, false, "费率"); if (rate <= 30) settings.CommissionRate = (string)value; } catch (ArgumentException) { }
                }
                if (document.TryGetValue("Tracking", out value) && value != null) {
                    Dictionary<string, object> records = value as Dictionary<string, object>;
                    if (records == null) throw new FormatException("持仓设置类型不正确。");
                    Dictionary<string, string> rawRecords = JsonFields(rawDocument["Tracking"]);
                    foreach (KeyValuePair<string, object> pair in records) {
                        if (!settings.Symbols.Contains(pair.Key)) continue;
                        string rawRecord = rawRecords.ContainsKey(pair.Key) ? rawRecords[pair.Key] : serializer.Serialize(pair.Value);
                        try { settings.Tracking[pair.Key] = DecodeRecord(pair.Value, rawRecord); }
                        catch (Exception error) {
                            if (!(error is ArgumentException || error is FormatException || error is InvalidCastException || error is OverflowException)) throw;
                            settings.RejectedTracking[pair.Key] = pair.Value;
                            settings.RejectedTrackingJson[pair.Key] = rawRecord;
                            settings.InvalidTracking[pair.Key] = error.Message;
                        }
                    }
                }
                UpdateIssues(settings);
            } catch (Exception error) {
                if (!(error is ArgumentException || error is FormatException || error is InvalidOperationException || error is IOException || error is UnauthorizedAccessException)) throw;
                settings = new AppSettings(); settings.WholeTrackingCorrupt = true; settings.HasInvalidPositions = true;
                string backup = path + ".corrupt-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss-fffffff", CultureInfo.InvariantCulture) + ".json";
                try {
                    File.Copy(path, backup, false);
                    Notice = "本地设置无法读取，原文件已备份；请核对并重新录入。";
                } catch (IOException) { originalBackupFailed = true; Notice = "本地设置无法读取，且备份失败；请保留原文件并检查目录权限。"; }
                  catch (UnauthorizedAccessException) { originalBackupFailed = true; Notice = "本地设置无法读取，且备份失败；请保留原文件并检查目录权限。"; }
            }
            currentSettings = settings;
            return settings;
        }

        public void Save(AppSettings settings)
        {
            if (originalBackupFailed) throw new IOException("原设置尚未成功备份，已停止保存以保留原始数据。");
            Dictionary<string, object> records = new Dictionary<string, object>();
            foreach (KeyValuePair<string, object> pair in settings.RejectedTracking)
                if (settings.Symbols.Contains(pair.Key)) records[pair.Key] = pair.Value;
            foreach (KeyValuePair<string, TrackingRecord> pair in settings.Tracking) {
                if (!settings.Symbols.Contains(pair.Key)) continue;
                pair.Value.Validate(); records[pair.Key] = EncodeRecord(pair.Value);
            }
            Dictionary<string, object> document = new Dictionary<string, object> {
                { "Version", 1 }, { "Symbols", settings.Symbols }, { "Tracking", records },
                { "Transparency", Math.Max(0, Math.Min(100, settings.Transparency)) }, { "Pinned", settings.Pinned },
                { "AutoHide", settings.AutoHide }, { "CommissionRate", settings.CommissionRate }, { "StartWithWindows", settings.StartWithWindows }
            };
            if (!double.IsNaN(settings.Left) && !double.IsInfinity(settings.Left)) document["Left"] = settings.Left;
            if (!double.IsNaN(settings.Top) && !double.IsInfinity(settings.Top)) document["Top"] = settings.Top;
            // Serialize rejected records from original JSON tokens, so even values outside Decimal's range survive.
            document.Remove("Tracking");
            string baseDocument = serializer.Serialize(document);
            List<string> rawRecords = new List<string>();
            foreach (KeyValuePair<string, object> pair in records) {
                string raw;
                if (settings.Tracking.ContainsKey(pair.Key) || !settings.RejectedTrackingJson.TryGetValue(pair.Key, out raw)) raw = serializer.Serialize(pair.Value);
                rawRecords.Add(serializer.Serialize(pair.Key) + ":" + raw);
            }
            string text = baseDocument.Substring(0, baseDocument.Length - 1) + ",\"Tracking\":{" + string.Join(",", rawRecords) + "}}";
            string directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory);
            string temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
            try {
                byte[] bytes = new UTF8Encoding(false).GetBytes(text);
                using (FileStream output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough)) {
                    output.Write(bytes, 0, bytes.Length); output.Flush(true);
                }
                if (File.Exists(path)) File.Replace(temporary, path, path + ".bak", true);
                else File.Move(temporary, path);
            } finally { if (File.Exists(temporary)) File.Delete(temporary); }
            foreach (string id in settings.RejectedTracking.Keys.ToList())
                if (!settings.Symbols.Contains(id) || settings.Tracking.ContainsKey(id)) { settings.RejectedTracking.Remove(id); settings.RejectedTrackingJson.Remove(id); settings.InvalidTracking.Remove(id); }
            foreach (string id in settings.Tracking.Keys.ToList()) if (!settings.Symbols.Contains(id)) settings.Tracking.Remove(id);
            UpdateIssues(settings);
            currentSettings = settings;
        }

        // Exact editable strings for a damaged entry; missing fields are absent, JSON null is returned as empty.
        public Dictionary<string, string> ReadRawTracking(string symbolId)
        {
            Dictionary<string, string> result = new Dictionary<string, string>();
            string raw;
            if (currentSettings == null || !currentSettings.RejectedTrackingJson.TryGetValue(symbolId, out raw) || !raw.TrimStart().StartsWith("{")) return result;
            foreach (KeyValuePair<string, string> field in JsonFields(raw)) {
                string token = field.Value.Trim();
                result[field.Key] = token == "null" ? "" : token.StartsWith("\"") ? serializer.Deserialize<string>(token) : token;
            }
            return result;
        }

        void UpdateIssues(AppSettings settings)
        {
            settings.HasInvalidPositions = settings.WholeTrackingCorrupt;
            foreach (object raw in settings.RejectedTracking.Values) {
                Dictionary<string, object> fields = raw as Dictionary<string, object>;
                if (fields == null || new [] { "CostPrice", "Quantity", "TotalCost", "PerShareCost", "PurchaseAmount", "CommissionRate" }.Any(key => fields.ContainsKey(key) && fields[key] != null))
                    settings.HasInvalidPositions = true;
            }
            Notice = settings.WholeTrackingCorrupt ? "本地设置无法读取，原文件已备份；请核对并重新录入。"
                : settings.RejectedTracking.Count > 0 ? "部分持仓或提醒配置异常，原字段已保留；请重新保存对应股票。" : null;
        }

        TrackingRecord DecodeRecord(object raw, string source)
        {
            Dictionary<string, object> original = raw as Dictionary<string, object>;
            if (original == null) throw new FormatException("持仓记录必须为JSON对象。");
            Dictionary<string, object> value = new Dictionary<string, object>(original);
            Dictionary<string, string> tokens = JsonFields(source);
            foreach (string key in new [] { "CostPrice", "TotalCost", "PerShareCost", "PurchaseAmount", "CommissionRate", "Upper", "Lower", "Quantity" }) {
                string token;
                if (tokens.TryGetValue(key, out token) && token != "null" && !token.StartsWith("\"")) value[key] = token;
            }
            TrackingRecord record = new TrackingRecord {
                CostPrice = ReadDecimal(value, "CostPrice"), TotalCost = ReadDecimal(value, "TotalCost"),
                PerShareCost = ReadDecimal(value, "PerShareCost"), PurchaseAmount = ReadDecimal(value, "PurchaseAmount"),
                CommissionRate = ReadDecimal(value, "CommissionRate"), Upper = ReadDecimal(value, "Upper"), Lower = ReadDecimal(value, "Lower"),
                UpperTriggered = ReadBool(value, "UpperTriggered", false), LowerTriggered = ReadBool(value, "LowerTriggered", false)
            };
            object field;
            if (value.TryGetValue("Quantity", out field) && field != null) {
                long quantity;
                string number = Convert.ToString(field, CultureInfo.InvariantCulture);
                if (!Regex.IsMatch(number, "^[0-9]+$") || !long.TryParse(number, NumberStyles.None, CultureInfo.InvariantCulture, out quantity)) throw new FormatException("持仓股数无效。");
                record.Quantity = quantity;
            }
            if (value.TryGetValue("ArmedAt", out field) && field != null) {
                DateTimeOffset instant;
                if (!(field is string) || !DateTimeOffset.TryParseExact((string)field, "o", CultureInfo.InvariantCulture, DateTimeStyles.None, out instant)) throw new FormatException("提醒启用时间无效。");
                record.ArmedAt = instant;
            }
            record.Validate(); return record;
        }

        static Dictionary<string, object> EncodeRecord(TrackingRecord record)
        {
            Dictionary<string, object> value = new Dictionary<string, object> {
                { "Quantity", record.Quantity }, { "UpperTriggered", record.UpperTriggered }, { "LowerTriggered", record.LowerTriggered },
                { "ArmedAt", record.ArmedAt.HasValue ? record.ArmedAt.Value.ToString("o", CultureInfo.InvariantCulture) : null }
            };
            // Decimal strings keep full cost precision through serializers and future application versions.
            AddDecimal(value, "CostPrice", record.CostPrice); AddDecimal(value, "TotalCost", record.TotalCost);
            AddDecimal(value, "PerShareCost", record.PerShareCost); AddDecimal(value, "PurchaseAmount", record.PurchaseAmount);
            AddDecimal(value, "CommissionRate", record.CommissionRate); AddDecimal(value, "Upper", record.Upper); AddDecimal(value, "Lower", record.Lower);
            return value;
        }

        static void AddDecimal(Dictionary<string, object> value, string key, decimal? number)
        { value[key] = number.HasValue ? TrackingService.Raw(number.Value) : null; }

        static decimal? ReadDecimal(Dictionary<string, object> value, string key)
        {
            object raw; if (!value.TryGetValue(key, out raw) || raw == null) return null;
            if (!(raw is string || raw is decimal || raw is int || raw is long || raw is double)) throw new FormatException(key + "数值类型无效。");
            string text = Convert.ToString(raw, CultureInfo.InvariantCulture);
            decimal result;
            if (!Regex.IsMatch(text, "^-?[0-9]+(?:\\.[0-9]+)?$") || !decimal.TryParse(text, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out result)) throw new FormatException(key + "数值无效。");
            // Validate the exact source string too; decimal.TryParse otherwise silently rounds overly precise values.
            decimal exact = TrackingService.Exact(text, null, true, key);
            return exact;
        }

        static bool ReadBool(Dictionary<string, object> value, string key, bool fallback)
        {
            object raw; if (!value.TryGetValue(key, out raw) || raw == null) return fallback;
            if (!(raw is bool)) throw new FormatException(key + "开关类型无效。");
            return (bool)raw;
        }

        static double ReadDouble(Dictionary<string, object> value, string key, double fallback)
        {
            object raw; double number;
            if (!value.TryGetValue(key, out raw) || raw == null || !double.TryParse(Convert.ToString(raw, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out number) || double.IsNaN(number) || double.IsInfinity(number)) return fallback;
            return number;
        }

        Dictionary<string, string> JsonFields(string json)
        {
            Dictionary<string, string> fields = new Dictionary<string, string>();
            int index = 0; SkipSpace(json, ref index);
            if (index >= json.Length || json[index++] != '{') throw new FormatException("设置必须为JSON对象。");
            while (index < json.Length) {
                SkipSpace(json, ref index);
                if (json[index] == '}') break;
                int keyStart = index; SkipString(json, ref index);
                string key = serializer.Deserialize<string>(json.Substring(keyStart, index - keyStart));
                SkipSpace(json, ref index);
                if (json[index++] != ':') throw new FormatException("JSON字段缺少冒号。");
                SkipSpace(json, ref index);
                int start = index, depth = 0;
                while (index < json.Length) {
                    char c = json[index];
                    if (c == '"') { SkipString(json, ref index); continue; }
                    if (c == '{' || c == '[') depth++;
                    else if (c == '}' || c == ']') { if (depth == 0) break; depth--; }
                    else if (c == ',' && depth == 0) break;
                    index++;
                }
                fields[key] = json.Substring(start, index - start).Trim();
                if (index < json.Length && json[index] == ',') index++;
                else break;
            }
            return fields;
        }

        static void SkipSpace(string json, ref int index) { while (index < json.Length && char.IsWhiteSpace(json[index])) index++; }
        static void SkipString(string json, ref int index)
        {
            if (index >= json.Length || json[index++] != '"') throw new FormatException("JSON字段名无效。");
            while (index < json.Length) {
                char c = json[index++];
                if (c == '\\') index++;
                else if (c == '"') return;
            }
            throw new FormatException("JSON字符串未结束。");
        }
    }
}
