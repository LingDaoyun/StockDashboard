using System;
using System.Globalization;
using System.IO;
using System.Collections.Generic;
using StockDashboard;

internal static class TrackingTests
{
    static int checks;
    static readonly DateTimeOffset Now = new DateTimeOffset(2026, 10, 28, 10, 0, 0, TimeSpan.FromHours(8));
    static void Check(bool value, string message) { if (!value) throw new Exception(message); checks++; }
    static void Reject(Action action, string message) { try { action(); } catch (ArgumentException) { checks++; return; } throw new Exception(message); }
    static TrackingRecord Build(string mode, string amount, string qty, string upper, string lower, TrackingRecord prior) {
        return TrackingService.Build("sh600108", mode, amount, qty, "2.5", upper, lower, prior, Now);
    }
    static int Main()
    {
        try { Run(); return 0; }
        catch (Exception error) { Console.Error.WriteLine("FAIL: " + error.Message); return 1; }
    }
    static void Run()
    {
        // These literal examples catch double charging, binary arithmetic, and wrong minimum/transfer rounding.
        FeeEstimate fee = TrackingService.EstimateFees("sh600000", "40000", "2.5");
        Check(fee.Commission == 10m && fee.TransferFee == .40m && fee.TotalCost == 40010.40m, "Shanghai fee breakdown");
        Check(TrackingService.EstimateFees("sz000001", "10000", "2.5").TotalCost == 10005m, "Shenzhen minimum commission");
        Check(TrackingService.EstimateFees("bj920000", "10000", "2.5").TransferFee == 0m, "Beijing no extra estimated transfer fee");
        Check(TrackingService.EstimateFees("sh600000", "20020", "2.5").TotalCost == 20025.21m, "Round each fee separately away from zero");
        Check(TrackingService.EstimateFees("sh600000", "500", "2.5").TransferFee == .01m, "Transfer half cent");
        Check(TrackingService.EstimateFees("sh600000", "499.99", "2.5").TransferFee == 0m, "Transfer below half cent");
        Check(TrackingService.EstimateFees("sz000001", "40000", "2.5125").TotalFees == 10.05m, "Precise rate");
        foreach (string bad in new [] { "0", "-1", "+1", "1e3", "1.000", "1.", "NaN", "1,000", "１", "1abc", "99999999999999999999999999999.99" })
            Reject(delegate { TrackingService.EstimateFees("sh600000", bad, "2.5"); }, "Reject invalid amount " + bad);
        foreach (string bad in new [] { "0", "-1", "30.01", "1e1", "2.", "NaN", "2.123456789012345678901234567891" })
            Reject(delegate { TrackingService.EstimateFees("sh600000", "1000", bad); }, "Reject invalid rate " + bad);
        TrackingRecord total = Build("total", "5062.08", "500", "13", "9", null);
        Check(total.Profit(12m).Amount == 937.92m && total.PurchaseAmount == null, "Actual cost authoritative");
        Check(total.CostPrice == 10.12416m, "Display average from total");
        TrackingRecord per = Build("perShare", "10.12345678", "500", "13", "9", null);
        Check(per.PerShareCost == 10.12345678m && per.TotalCost == null && per.Profit(12m).Amount == 938.27m, "Keep eight-place cost");
        Check(per.EffectiveCost == 5061.72839m && per.Profit(12m).Percent > 18.53m, "Percent uses unrounded total");
        Check(Build("perShare", "-1.23456789", "600", "", "", null).Profit(10m).Amount == 6740.74m, "Negative cost supported");
        Check(Build("perShare", "0", "600", "", "", null).Profit(10m).Percent == null, "Zero cost has no profit percentage");
        Check(Build("perShare", "0.015", "1", "", "", null).Profit(.01m).Amount == -.01m, "Negative half cent away from zero");
        Check(TrackingService.Money(-.004m, true) == "+0.00", "No negative zero");
        foreach (string bad in new [] { "1.123456789", "+1", "1e2", "1.", "99999999999999999999999.99999999" })
            Reject(delegate { Build("perShare", bad, "100", "", "", null); }, "Reject inexact per-share cost");
        foreach (string bad in new [] { "0", "-1", "1.5", "1e2", "+1", "１００", "9223372036854775808" })
            Reject(delegate { Build("total", "100", bad, "", "", null); }, "Reject quantity");
        Reject(delegate { Build("total", "100", "", "", "", null); }, "Reject missing quantity");
        Reject(delegate { Build("total", "", "100", "", "", null); }, "Reject missing cost");
        Reject(delegate { Build("total", "", "", "9", "10", null); }, "Reject inverted thresholds");
        Reject(delegate { Build("total", "", "", "10", "10", null); }, "Reject equal thresholds");
        Reject(delegate { Build("other", "100", "100", "", "", null); }, "Reject unknown input mode");
        Check(!Build("total", "", "", "13", "", null).HasPosition, "Alerts independent of positions");

        // These state transitions catch stale/future/source-pre-arm alerts and repeated notifications.
        TrackingRecord alert = Build("total", "", "", "12", "8", null);
        Check(alert.TakeAlerts(12m, Now.AddSeconds(-1), Now, false).Count == 0, "Pre-arm quote ignored");
        Check(alert.TakeAlerts(12m, Now, Now.AddSeconds(31), false).Count == 0, "Stale quote ignored");
        Check(alert.TakeAlerts(12m, Now.AddSeconds(6), Now, false).Count == 0, "Future quote ignored");
        Check(alert.TakeAlerts(12m, Now, Now, true).Count == 0 && !alert.UpperTriggered, "Auction never consumes alert");
        Check(alert.TakeAlerts(12m, Now, Now.AddSeconds(30), false).Count == 1 && alert.UpperTriggered, "Inclusive threshold and age boundary");
        Check(alert.TakeAlerts(13m, Now, Now, false).Count == 0, "One shot across repeated quotes");
        Check(alert.TakeAlerts(8m, Now, Now, false).Count == 1 && alert.LowerTriggered, "Independent lower direction");
        TrackingRecord changedPosition = Build("total", "1000", "100", "12", "8", alert);
        Check(changedPosition.UpperTriggered && changedPosition.LowerTriggered && changedPosition.ArmedAt == alert.ArmedAt, "Position edit preserves alert state");
        TrackingRecord changedThreshold = Build("total", "1000", "100", "13", "8", changedPosition);
        Check(!changedThreshold.UpperTriggered && changedThreshold.LowerTriggered, "Changing one threshold resets only its direction");
        changedThreshold.Rearm(Now.AddMinutes(1));
        Check(!changedThreshold.UpperTriggered && !changedThreshold.LowerTriggered && changedThreshold.TakeAlerts(14m, Now, Now, false).Count == 0, "Rearm waits for a new quote");

        TrackingRecord purchase = Build("purchase", "40000", "4000", "13", "", null);
        Check(purchase.TotalCost == 40010.40m && purchase.IsEstimated, "Estimate saved once");
        TrackingRecord purchaseAgain = Build("purchase", "40000", "4000", "14", "", purchase);
        Check(purchaseAgain.TotalCost == 40010.40m, "Reopen and alert edit never double charge");
        purchase.CommissionRate = null;
        TrackingRecord oldRate = TrackingService.Build("sh600108", "purchase", "40000", "4000", "3", "14", "", purchase, Now);
        Check(oldRate.TotalCost == 40010.40m && oldRate.CommissionRate == null, "Unknown historical rate preserved on alert-only edit");
        TrackingRecord actualAlertEdit = TrackingService.Build("sh600108", "purchase", "", "500", "invalid", "14", "9", total, Now);
        Check(actualAlertEdit.TotalCost == 5062.08m && !actualAlertEdit.IsEstimated, "Blank purchase field preserves real cost during alert edit");
        TrackingRecord cleared = Build("total", "", "", "13", "", total);
        Check(!cleared.HasPosition && cleared.HasAlerts, "Explicitly clear paired position fields");

        // Repairing damaged holdings must keep already-consumed alert directions without importing the bad cost.
        var rawAlertState = new Dictionary<string, string> {
            { "Quantity", "bad" }, { "TotalCost", "broken" }, { "Upper", "12" }, { "Lower", "8" },
            { "UpperTriggered", "true" }, { "LowerTriggered", "false" },
            { "ArmedAt", Now.AddHours(-1).ToString("o", CultureInfo.InvariantCulture) }
        };
        TrackingRecord repairPrior = TrackingService.AlertStateFromRaw(rawAlertState);
        Check(!repairPrior.HasPosition && repairPrior.Quantity == null && repairPrior.TotalCost == null && repairPrior.CostPrice == null,
            "Repair prior imports alert state only, never malformed position data");
        TrackingRecord repairedPosition = Build("total", "1000", "100", "12", "8", repairPrior);
        Check(repairedPosition.UpperTriggered && !repairedPosition.LowerTriggered && repairedPosition.ArmedAt == Now.AddHours(-1),
            "Repairing only a holding preserves unchanged alert flags and original armed time");
        Check(repairedPosition.TakeAlerts(13m, Now, Now, false).Count == 0 && repairedPosition.TakeAlerts(8m, Now, Now, false).Count == 1,
            "Repair must not repeat consumed upper alert while unused lower alert still fires");
        TrackingRecord repairedChangedThreshold = Build("total", "1000", "100", "13", "8", repairPrior);
        Check(!repairedChangedThreshold.UpperTriggered && repairedChangedThreshold.ArmedAt == Now,
            "Explicitly changing threshold while repairing starts a new alert condition");
        var partiallyInvalidAlerts = new Dictionary<string, string> {
            { "Upper", "1.123456789012345678901234567891" }, { "Lower", "8" },
            { "UpperTriggered", "true" }, { "LowerTriggered", "true" }, { "ArmedAt", "invalid date" }
        };
        TrackingRecord validLowerOnly = TrackingService.AlertStateFromRaw(partiallyInvalidAlerts);
        Check(validLowerOnly.Upper == null && !validLowerOnly.UpperTriggered && validLowerOnly.Lower == 8m && validLowerOnly.LowerTriggered && validLowerOnly.ArmedAt == null,
            "Ignore inexact thresholds and invalid dates, retain independently valid direction");
        foreach (string invalidPrice in new[] { "0", "-1", "NaN", "1e2", "12abc", "+1" }) {
            var malformedAlerts = new Dictionary<string, string> { { "Upper", invalidPrice }, { "UpperTriggered", "true" }, { "ArmedAt", Now.ToString("o", CultureInfo.InvariantCulture) } };
            TrackingRecord ignored = TrackingService.AlertStateFromRaw(malformedAlerts);
            Check(!ignored.HasAlerts && !ignored.HasTriggeredAlerts && ignored.ArmedAt == null, "Ignore malformed alert price and orphan state " + invalidPrice);
        }
        TrackingRecord noRawAlerts = TrackingService.AlertStateFromRaw(null);
        Check(!noRawAlerts.HasPosition && !noRawAlerts.HasAlerts, "Missing raw record produces empty alert prior");
        TrackingRecord invalidFlag = TrackingService.AlertStateFromRaw(new Dictionary<string, string> { { "Upper", "12" }, { "UpperTriggered", "yes" } });
        Check(invalidFlag.Upper == 12m && !invalidFlag.UpperTriggered, "Invalid boolean never invents consumed alert state");

        string directory = Path.Combine(Path.GetTempPath(), "StockDashboardTrackingTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try {
            string path = Path.Combine(directory, "settings.json");
            SettingsStore store = new SettingsStore(path);
            AppSettings settings = store.Load();
            Check(settings.Symbols.Count == 0 && settings.AutoHide && settings.Transparency == 30, "First launch has no watchlist and retains defaults");
            settings.Symbols.Add("sh600108"); settings.Tracking["sh600108"] = per; settings.Left = -1920; settings.Top = 20;
            per.UpperTriggered = true; store.Save(settings);
            AppSettings restored = new SettingsStore(path).Load();
            Check(restored.Tracking["sh600108"].PerShareCost == 10.12345678m && restored.Tracking["sh600108"].UpperTriggered, "Restart preserves precise cost and one-shot state");
            Check(restored.Left == -1920 && restored.Top == 20, "Negative monitor position survives save");
            restored.Transparency = 75; store.Save(restored);
            Check(new SettingsStore(path).Load().Transparency == 75 && File.Exists(path + ".bak"), "Atomic replacement preserves previous valid document");
            string safeDocument = File.ReadAllText(path);
            bool blockedWrite = false;
            using (FileStream locked = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                restored.Transparency = 20;
                try { store.Save(restored); } catch (IOException) { blockedWrite = true; }
            }
            Check(blockedWrite && File.ReadAllText(path) == safeDocument, "Failed atomic replacement leaves original document intact");
            Check(Directory.GetFiles(directory, "settings.json.tmp-*").Length == 0, "Failed save cleans only its own temporary file");
            File.WriteAllText(path, "{\"Symbols\":[\"sh600108\",\"sz000001\"],\"Tracking\":{\"sh600108\":{\"Quantity\":\"bad\",\"mystery\":\"retain\"},\"sz000001\":{\"TotalCost\":\"1005.00\",\"Quantity\":100,\"UpperTriggered\":false,\"LowerTriggered\":false}}}");
            AppSettings partial = store.Load();
            Check(partial.Tracking.ContainsKey("sz000001") && !partial.Tracking.ContainsKey("sh600108") && partial.HasInvalidPositions && store.Notice != null, "Bad record is isolated without false complete profit");
            store.Save(partial);
            Check(File.ReadAllText(path).Contains("retain"), "Saving another stock preserves damaged original fields");
            partial.Tracking["sh600108"] = total; store.Save(partial);
            Check(store.Notice == null && !File.ReadAllText(path).Contains("retain") && partial.InvalidTracking.Count == 0, "Explicit repair replaces malformed record");
            partial.Symbols.Remove("sh600108"); store.Save(partial);
            Check(!new SettingsStore(path).Load().Tracking.ContainsKey("sh600108"), "Removing symbol removes holding and alerts");
            File.WriteAllText(path, "{\"Symbols\":[\"sh600108\"],\"Tracking\":{\"sh600108\":{\"PerShareCost\":1234567890123456789012.12345678,\"Quantity\":1,\"Upper\":\"12\",\"UpperTriggered\":true}}}");
            AppSettings excessivePrecision = store.Load();
            Check(!excessivePrecision.Tracking.ContainsKey("sh600108") && excessivePrecision.InvalidTracking.Count == 1, "Reject raw JSON decimals that would be silently rounded by deserializer");
            Dictionary<string, string> editable = store.ReadRawTracking("sh600108");
            Check(editable["PerShareCost"] == "1234567890123456789012.12345678" && editable["Upper"] == "12" && editable["UpperTriggered"] == "true", "Editor receives original exact field text and alert state for repair");
            store.Save(excessivePrecision);
            Check(File.ReadAllText(path).Contains("1234567890123456789012.12345678"), "Preserve exact malformed numeric token when editing another setting");
            TrackingRecord explicitOldRate = TrackingService.Build("sh600108", "purchase", "40000", "4000", "4", "14", "", purchase, Now, "3");
            Check(explicitOldRate.TotalCost == 40016.40m && explicitOldRate.CommissionRate == 4m, "Explicitly changed unknown historical rate recalculates once");
            File.WriteAllText(path, "{broken document");
            AppSettings corrupt = store.Load();
            Check(store.Notice != null && corrupt.HasInvalidPositions && Directory.GetFiles(directory, "settings.json.corrupt-*").Length == 1, "Whole corruption backed up and surfaced");
            corrupt.Symbols.Add("sh600108"); corrupt.Tracking["sh600108"] = per; store.Save(corrupt);
            Check(store.Notice != null, "Whole corruption warning stays for current session");
            Check(new SettingsStore(path).Load().Tracking["sh600108"].PerShareCost == 10.12345678m, "Recovery is readable after restart");
        } finally { Directory.Delete(directory, true); }
        Console.WriteLine("PASS: " + checks + " tracking / fee / settings assertions");
    }
}
