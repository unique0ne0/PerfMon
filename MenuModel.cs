using WpfContextMenu = System.Windows.Controls.ContextMenu;
using WpfMenuItem    = System.Windows.Controls.MenuItem;
using WpfSeparator   = System.Windows.Controls.Separator;
using FormsMenuStrip = System.Windows.Forms.ContextMenuStrip;
using FormsMenuItem  = System.Windows.Forms.ToolStripMenuItem;
using FormsSeparator = System.Windows.Forms.ToolStripSeparator;
using ToolStripItem  = System.Windows.Forms.ToolStripItem;

namespace PerfMonCS;

// 프레임워크 독립 메뉴 트리. MainWindow가 이 모델을 만들고,
// 오버레이(WPF)·트레이(WinForms) 두 렌더러가 각자 그려낸다. → 메뉴 내용 단일 소스.
public abstract record MenuNode;

public sealed record MenuItemNode(
    string Label, Action OnClick, bool Checkable = false, Func<bool>? Checked = null) : MenuNode;

public sealed record MenuSubNode(string Label, IReadOnlyList<MenuNode> Children) : MenuNode;

public sealed record MenuSepNode : MenuNode;

public static class MenuRenderer
{
    // ── WPF (오버레이) ──────────────────────────────────────────────────
    public static WpfContextMenu ToWpf(IReadOnlyList<MenuNode> model)
    {
        var menu = new WpfContextMenu();
        FillWpf(menu, model);
        return menu;
    }

    // 기존 메뉴 인스턴스를 최신 모델로 다시 채운다(열릴 때 체크 상태 갱신용).
    public static void FillWpf(WpfContextMenu menu, IReadOnlyList<MenuNode> model)
    {
        menu.Items.Clear();
        foreach (var node in model) menu.Items.Add(ToWpfItem(node));
    }

    private static object ToWpfItem(MenuNode node) => node switch
    {
        MenuSepNode => new WpfSeparator(),
        MenuSubNode sub => WpfSub(sub),
        MenuItemNode it => WpfLeaf(it),
        _ => new WpfSeparator(),
    };

    private static WpfMenuItem WpfSub(MenuSubNode sub)
    {
        var mi = new WpfMenuItem { Header = sub.Label };
        foreach (var c in sub.Children) mi.Items.Add(ToWpfItem(c));
        return mi;
    }

    private static WpfMenuItem WpfLeaf(MenuItemNode it)
    {
        var mi = new WpfMenuItem { Header = it.Label };
        if (it.Checkable) { mi.IsCheckable = true; mi.IsChecked = it.Checked?.Invoke() ?? false; }
        mi.Click += (_, _) => it.OnClick();
        return mi;
    }

    // ── WinForms (트레이) ───────────────────────────────────────────────
    public static FormsMenuStrip ToForms(IReadOnlyList<MenuNode> model)
    {
        var menu = new FormsMenuStrip();
        FillForms(menu, model);
        return menu;
    }

    public static void FillForms(FormsMenuStrip menu, IReadOnlyList<MenuNode> model)
    {
        menu.Items.Clear();
        foreach (var node in model) menu.Items.Add(ToFormsItem(node));
    }

    private static ToolStripItem ToFormsItem(MenuNode node) => node switch
    {
        MenuSepNode => new FormsSeparator(),
        MenuSubNode sub => FormsSub(sub),
        MenuItemNode it => FormsLeaf(it),
        _ => new FormsSeparator(),
    };

    private static FormsMenuItem FormsSub(MenuSubNode sub)
    {
        var mi = new FormsMenuItem(sub.Label);
        foreach (var c in sub.Children) mi.DropDownItems.Add(ToFormsItem(c));
        return mi;
    }

    private static FormsMenuItem FormsLeaf(MenuItemNode it)
    {
        var mi = new FormsMenuItem(it.Label);
        if (it.Checkable) mi.Checked = it.Checked?.Invoke() ?? false;
        mi.Click += (_, _) => it.OnClick();
        return mi;
    }
}
