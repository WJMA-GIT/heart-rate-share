using HeartRateShare.Desktop;
using Xunit;

namespace HeartRateShare.Tests;

/// 跨线程修复的守门测试：后台线程推 100 条，必须全部经过 UiDispatch，且不见异常。
public class DispatchTests
{
    [Fact]
    public void WithoutDispatcherRunsInline()
    {
        UiDispatch.Dispatcher = null;
        var ran = false;
        UiDispatch.Post(() => ran = true);
        Assert.True(ran);
    }

    [Fact]
    public void BackgroundPushesAllGoThroughDispatcher()
    {
        var queue = new Queue<Action>();
        var posted = 0;
        UiDispatch.Dispatcher = action =>
        {
            lock (queue) { queue.Enqueue(action); posted++; }
        };
        try
        {
            // 模拟 WS/UDP/BLE 回调：100 个后台线程各推一条
            Parallel.For(0, 100, index =>
                UiDispatch.Post(() => { /* 这里代表"改绑定集合" */ }));

            Assert.Equal(100, posted);

            var applied = 0;
            while (true)
            {
                Action? next = null;
                lock (queue) { if (queue.Count > 0) next = queue.Dequeue(); }
                if (next is null) break;
                next();
                applied++;
            }
            Assert.Equal(100, applied);
        }
        finally
        {
            UiDispatch.Dispatcher = null;
        }
    }
}
