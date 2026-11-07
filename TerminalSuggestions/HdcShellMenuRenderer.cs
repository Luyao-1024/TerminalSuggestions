using System;
using System.Reflection;

namespace TerminalSuggestions
{
    // A terminal may resize while PSReadLine is in the middle of drawing a
    // frame. Keep that recoverable console race inside the CLR boundary so it
    // does not become an error in the PowerShell custom key handler/$Error.
    public static class HdcShellMenuRenderer
    {
        public static bool TryInvoke(MethodInfo method, object target, object[] arguments)
        {
            try
            {
                method.Invoke(target, arguments);
                return true;
            }
            catch (TargetInvocationException error) when (
                error.GetBaseException() is ArgumentOutOfRangeException range &&
                (range.ParamName == "top" || range.ParamName == "left"))
            {
                return false;
            }
        }
    }
}
