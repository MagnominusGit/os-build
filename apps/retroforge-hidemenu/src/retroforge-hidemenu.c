// retroforge-hidemenu — an LD_PRELOAD shim that gives every QMainWindow after the first a zero-height
// menu bar.
//
// WHY. On a dual-screen board melonDS runs a second window (Instance0.Window1) that gamescope shows
// on the bottom panel (gamescope patches 0040-0042). melonDS hides a window's menu bar only when
// that window goes fullscreen, and its -f option fullscreens the first window alone; its fullscreen
// hotkey toggles every window at once, so it would take the first one out again. The second window
// therefore showed File / System / ... above the DS bottom screen (HW 2026-10-12, Thor Lite).
//
// HOW. melonDS builds each window's QMenuBar and hands it over with QMainWindow::setMenuBar(), a
// non-virtual call from its own code into Qt, so it can be interposed. From the second call on, the
// real setMenuBar() runs and then QWidget::setFixedHeight(0), which is what melonDS's own fullscreen
// does to the bar ("don't use hide() as menubar actions stop working"). The first window keeps its
// menu: in melonDS's own GUI (retroforge-launch --gui) that menu is the whole interface. With a single
// window (every single-screen board) nothing changes.
//
// The C++ methods are called through their Itanium-mangled names: on aarch64 (and x86_64) a
// non-virtual member function takes `this` as its first argument, like the functions below.
// Built for the image with the build container's cross toolchain (see the Makefile): it only
// references dlsym, which every glibc the image or an AppImage bundles has.

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>

typedef void (*set_menu_bar_fn)(void *main_window, void *menu_bar);
typedef void (*set_fixed_height_fn)(void *widget, int height);

#define SET_MENU_BAR "_ZN11QMainWindow10setMenuBarEP8QMenuBar"
#define SET_FIXED_HEIGHT "_ZN7QWidget14setFixedHeightEi"

void _ZN11QMainWindow10setMenuBarEP8QMenuBar(void *main_window, void *menu_bar)
{
    // Qt widgets live on the GUI thread, so no locking.
    static set_menu_bar_fn real;
    static set_fixed_height_fn set_fixed_height;
    static unsigned int calls;

    if (!real)
        real = (set_menu_bar_fn)dlsym(RTLD_NEXT, SET_MENU_BAR);
    if (!set_fixed_height)
        set_fixed_height = (set_fixed_height_fn)dlsym(RTLD_DEFAULT, SET_FIXED_HEIGHT);
    if (!real)
        return;

    real(main_window, menu_bar);

    if (calls++ > 0 && menu_bar && set_fixed_height)
        set_fixed_height(menu_bar, 0);
}
