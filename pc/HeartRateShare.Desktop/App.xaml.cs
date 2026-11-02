using System.Windows;

namespace HeartRateShare.Desktop;

public partial class App : Application
{
    public static bool MockMode { get; private set; }

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        MockMode = e.Args.Contains("--mock");
        // 所有后台回调统一回到 UI 线程（见 UiDispatch）
        UiDispatch.Dispatcher = action => Dispatcher.BeginInvoke(action);
        AppState.Current.Start();
        MainWindow = new MainWindow();
        MainWindow.Show();
    }
}
