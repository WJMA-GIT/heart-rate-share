namespace HeartRateShare.Desktop;

/// 唯一的「回 UI 线程」入口。
///
/// WS 收包 / UDP 广播 / BLE watcher / 定时器都在后台线程；直接改绑定集合就是
/// 「调用线程无法访问此对象，因为另一个线程拥有该对象」。所有回调都必须走这里。
public static class UiDispatch
{
    /// App 启动时设成 `a => Application.Current.Dispatcher.BeginInvoke(a)`。
    /// 没设置时（单测/无 UI 进程）就地执行。
    public static Action<Action>? Dispatcher { get; set; }

    public static void Post(Action action)
    {
        var dispatcher = Dispatcher;
        if (dispatcher is null)
        {
            action();
            return;
        }
        dispatcher(action);
    }
}
