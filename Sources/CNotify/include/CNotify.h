// Darwin notifications are not exposed through Swift's Darwin module, so this shim
// re-exports <notify.h>. notify_register_dispatch takes a block, which imports as a
// capturing Swift closure — cleaner than the CFNotificationCenter C-callback dance.
#ifndef CNOTIFY_H
#define CNOTIFY_H
#include <notify.h>
#endif
