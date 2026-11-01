using System.Windows;

namespace HeartRateShare.Desktop;

public partial class App : Application
{
    public static bool MockMode { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        MockMode = e.Args.Contains("--mock");
        AppState.Current.Start();
        MainWindow = new MainWindow();
        MainWindow.Show();
    }
}
