using System;
using System.Runtime.InteropServices;
namespace CodexUsageMonitor;

internal static class CodexMiniGlass {
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
    [DllImport("user32.dll", EntryPoint="GetWindowLongW")] static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint="SetWindowLongW", SetLastError=true)] static extern int SetWindowLong(IntPtr window, int index, int value);
    [DllImport("user32.dll", SetLastError=true)] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint="DefWindowProcW")] static extern IntPtr DefWindowProc(IntPtr window, int message, IntPtr wParam, IntPtr lParam);
    public static int CaptionFillResult { get; private set; }
    public static int InactiveAppearanceMessages { get; private set; }
    public static IntPtr FilterBackdropActivation(IntPtr window, int message, IntPtr wParam, IntPtr lParam, ref bool handled) {
        if(message==0x0086) { // WM_NCACTIVATE: frame appearance, not WM_ACTIVATE/input focus.
            if(wParam==IntPtr.Zero)InactiveAppearanceMessages++;
            handled=true;
            // Retain DWM's acrylic appearance without painting a native title bar.
            DefWindowProc(window,message,new IntPtr(1),new IntPtr(-1));
            return new IntPtr(1); // Allow the real active window/input focus to change.
        }
        return IntPtr.Zero;
    }
    public static void RefreshBackdropAppearance(IntPtr window) {
        DefWindowProc(window,0x0086,new IntPtr(1),new IntPtr(-1));
    }
    public static bool HasSystemCaptionButtons(IntPtr window) {
        return (GetWindowLong(window,-16)&0x00080000)!=0;
    }
    public static void HideSystemCaptionButtons(IntPtr window) {
        // Keep WS_CAPTION for DWM's rounded frame, remove WS_SYSMENU so it cannot paint
        // a second close button/title strip. UseAeroCaptionButtons only changes hit testing.
        int style=GetWindowLong(window,-16);
        if((style&0x00080000)==0)return;
        if(SetWindowLong(window,-16,style&~0x00080000)==0)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        // Recalculate the frame without moving, resizing, activating or changing z-order.
        if(!SetWindowPos(window,IntPtr.Zero,0,0,0,0,0x0037))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public static int Enable(IntPtr window) {
        HideSystemCaptionButtons(window);
        // WindowChrome retains the native frame. DWM owns its only rounded edge and border.
        int dark=1, corners=2, border=0x00807066, backdrop=3, caption=-2;
        DwmSetWindowAttribute(window,20,ref dark,4);
        DwmSetWindowAttribute(window,33,ref corners,4);
        DwmSetWindowAttribute(window,34,ref border,4);
        // Suppress the system accent-colored caption fill over the custom WPF header.
        CaptionFillResult=DwmSetWindowAttribute(window,35,ref caption,4);
        // WindowChrome already extends the frame to the entire client area.
        return DwmSetWindowAttribute(window,38,ref backdrop,4);
    }
    public static int ReadBackdrop(IntPtr window) {
        int value; return DwmGetWindowAttribute(window,38,out value,4)<0 ? -1 : value;
    }
}