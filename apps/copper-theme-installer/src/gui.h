/* gui.h -- the GTK review window. */
#ifndef COPPER_THEME_GUI_H
#define COPPER_THEME_GUI_H

/* Opens the graphical installer.  If archive_path is non-NULL the archive is
 * inspected immediately; otherwise the window starts at the file chooser. */
int gui_run(const char *archive_path);

#endif
