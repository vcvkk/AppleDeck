/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The bridging header: the only C this app has is the guest bridge, and it is
 * reached through here rather than through a module map because the app links
 * it directly into its own binary (iOS cannot spawn a helper process).
 */
#ifndef APPLEDECK_BRIDGING_HEADER_H
#define APPLEDECK_BRIDGING_HEADER_H

#include "qemu_bridge.h"

#endif /* APPLEDECK_BRIDGING_HEADER_H */