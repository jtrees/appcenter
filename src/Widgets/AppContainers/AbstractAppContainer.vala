/*
* Copyright (c) 2016–2018 elementary, Inc. (https://elementary.io)
*
* This program is free software; you can redistribute it and/or
* modify it under the terms of the GNU General Public
* License as published by the Free Software Foundation; either
* version 2 of the License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
* General Public License for more details.
*
* You should have received a copy of the GNU General Public
* License along with this program; if not, write to the
* Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
* Boston, MA 02110-1301 USA
*/

namespace AppCenter {
    public static void set_widget_visibility (Gtk.Widget widget, bool show) {
        if (show) {
            widget.no_show_all = false;
            widget.show_all ();
        } else {
            widget.no_show_all = true;
            widget.hide ();
        }
    }

    public static void set_stack_visibility (Gtk.Stack stack, bool show) {
        if (show) {
            stack.set_visible_child_name ("CHILD");
        } else {
            stack.set_visible_child_name ("NONE");
        }
    }

    public abstract class AbstractAppContainer : Gtk.Grid {
        public AppCenterCore.Package package { get; construct set; }
        protected bool show_uninstall { get; set; default = true; }
        protected bool show_open { get; set; default = true; }

        protected Gtk.Overlay image;
        protected Gtk.Image inner_image;
        protected Gtk.Label package_name;
        protected Gtk.Label package_author;
        protected Gtk.Label package_summary;

        protected Widgets.ContentWarningDialog content_warning;
        protected Widgets.HumbleButton action_button;
        protected Gtk.Button uninstall_button;
        protected Gtk.Button open_button;
        protected Gtk.Stack action_button_stack;
        protected Gtk.Stack uninstall_button_stack;
        protected Gtk.Stack open_button_stack;

        protected Gtk.Grid progress_grid;
        protected Gtk.Grid button_grid;
        protected Gtk.ProgressBar progress_bar;
        protected Gtk.Button cancel_button;
        protected Gtk.SizeGroup action_button_group;
        protected Gtk.Stack action_stack;

        private Settings settings;
        private Mutex action_mutex = Mutex ();
        private Cancellable action_cancellable = new Cancellable ();

        private uint state_source = 0U;

        private enum ActionResult {
            NONE = 0,
            HIDE_BUTTON = 1,
            ADD_TO_INSTALLED_SCREEN = 2
        }

        public bool is_os_updates {
            get {
                return package.is_os_updates;
            }
        }

        public bool is_driver {
            get {
                return package.is_driver;
            }
        }

        public bool update_available {
            get {
                return package.update_available || package.is_updating;
            }
        }

        public bool is_updating {
            get {
                return package.is_updating;
            }
        }

        public string name_label {
            get {
                return package_name.label;
            }
        }

        public bool action_sensitive {
            set {
                action_button.sensitive = value;
            }
        }

        public bool payments_enabled {
            get {
                if (package == null || package.component == null || !package.is_native || package.is_os_updates) {
                    return false;
                }

                return package.get_payments_key () != null;
            }
        }

        protected bool updates_view = false;

        construct {
            image = new Gtk.Overlay ();
            inner_image = new Gtk.Image ();
            image.add (inner_image);

            settings = Settings.get_default ();

            package_author = new Gtk.Label (null);
            package_name = new Gtk.Label (null);
            package_summary = new Gtk.Label (null);

            action_button = new Widgets.HumbleButton ();
            action_button_stack = new Gtk.Stack ();
            action_button_stack.add_named (action_button, "CHILD");
            action_button_stack.add_named (new Gtk.EventBox (), "NONE");
            action_button_stack.hhomogeneous = false;

            action_button.download_requested.connect (() => {
                if (settings.content_warning == true && package.is_explicit) {
                    content_warning = new Widgets.ContentWarningDialog (this.package_name.label);
                    content_warning.transient_for = (Gtk.Window) get_toplevel ();

                    content_warning.download_requested.connect (() => {
                        action_clicked.begin ();
                    });

                    content_warning.show ();
                } else {
                    action_clicked.begin ();
                }
            });

            action_button.payment_requested.connect ((amount) => {
                if (settings.content_warning == true && package.is_explicit) {
                    content_warning = new Widgets.ContentWarningDialog (this.package_name.label);
                    content_warning.transient_for = (Gtk.Window) get_toplevel ();

                    content_warning.download_requested.connect (() => {
                        show_stripe_dialog (amount);
                    });

                    content_warning.show ();
                } else {
                    show_stripe_dialog (amount);
                }
            });

            uninstall_button = new Gtk.Button.with_label (_("Uninstall"));
            uninstall_button_stack = new Gtk.Stack ();
            uninstall_button_stack.add_named (uninstall_button, "CHILD");
            uninstall_button_stack.add_named (new Gtk.EventBox (), "NONE");
            uninstall_button_stack.hhomogeneous = false;

            uninstall_button.clicked.connect (() => uninstall_clicked.begin ());

            open_button = new Gtk.Button.with_label (_("Open"));
            open_button_stack = new Gtk.Stack ();
            open_button_stack.add_named (open_button, "CHILD");
            open_button_stack.add_named (new Gtk.EventBox (), "NONE");
            open_button_stack.hhomogeneous = false;

            open_button.clicked.connect (launch_package_app);

            button_grid = new Gtk.Grid ();
            button_grid.valign = Gtk.Align.CENTER;
            button_grid.halign = Gtk.Align.END;
            button_grid.hexpand = false;

            button_grid.add (uninstall_button_stack);
            button_grid.add (action_button_stack);
            button_grid.add (open_button_stack);

            progress_bar = new Gtk.ProgressBar ();
            progress_bar.show_text = true;
            progress_bar.valign = Gtk.Align.CENTER;
            /* Request a width large enough for the longest text to stop width of
             * progress bar jumping around, but allow space for long package names */
            progress_bar.width_request = 250;

            cancel_button = new Gtk.Button.with_label (_("Cancel"));
            cancel_button.valign = Gtk.Align.END;
            cancel_button.halign = Gtk.Align.END;
            cancel_button.clicked.connect (() => action_cancelled ());

            progress_grid = new Gtk.Grid ();
            progress_grid.halign = Gtk.Align.END;
            progress_grid.valign = Gtk.Align.CENTER;
            progress_grid.column_spacing = 12;
            progress_grid.attach (progress_bar, 0, 0, 1, 1);
            progress_grid.attach (cancel_button, 1, 0, 1, 1);

            action_button_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);
            action_button_group.add_widget (action_button);
            action_button_group.add_widget (uninstall_button);
            action_button_group.add_widget (cancel_button);
            action_button_group.add_widget (open_button);

            action_stack = new Gtk.Stack ();
            action_stack.hexpand = true;
            action_stack.transition_type = Gtk.StackTransitionType.CROSSFADE;
            action_stack.add_named (button_grid, "buttons");
            action_stack.add_named (progress_grid, "progress");
            action_stack.show_all ();

            destroy.connect (() => {
                if (state_source > 0) {
                    GLib.Source.remove (state_source);
                }
            });
        }

        private void show_stripe_dialog (int amount) {
            var stripe = new Widgets.StripeDialog (
                amount,
                package_name.label,
                package.component.id.replace (".desktop", ""),
                package.get_payments_key ()
            );

            stripe.transient_for = (Gtk.Window) get_toplevel ();

            stripe.download_requested.connect (() => {
                action_clicked.begin ();

                settings.add_paid_app (package.component.get_id ());
            });

            stripe.show ();
        }

        protected virtual void set_up_package (uint icon_size = 48) {
            package_name.label = package.get_name ();

            if (package.component.get_id () != AppCenterCore.Package.OS_UPDATES_ID) {
                package_author.label = package.author_title;
            }

            var scale_factor = inner_image.get_scale_factor ();

            var plugin_host_package = package.get_plugin_host_package ();
            if (package.is_plugin && plugin_host_package != null) {
                inner_image.gicon = package.get_icon (icon_size, scale_factor);
                var overlay_gicon = plugin_host_package.get_icon (icon_size / 2, scale_factor);
                var badge_icon_size = Gtk.IconSize.LARGE_TOOLBAR;
                if (icon_size >= 128) {
                    badge_icon_size = Gtk.IconSize.DIALOG;
                }

                var overlay_image = new Gtk.Image.from_gicon (overlay_gicon, badge_icon_size);
                overlay_image.halign = overlay_image.valign = Gtk.Align.END;
                image.add_overlay (overlay_image);
            } else {
                inner_image.gicon = package.get_icon (icon_size, scale_factor);
            }

            package.notify["state"].connect (on_package_state_changed);

            package.change_information.progress_changed.connect (update_progress);
            package.change_information.status_changed.connect (update_progress_status);

            update_progress_status ();
            update_progress ();
            update_state (true);
        }

        private void on_package_state_changed () {
            if (state_source > 0) {
                return;
            }

            state_source = Idle.add (() => {
                update_state ();
                state_source = 0U;
                return GLib.Source.REMOVE;
            });
        }

        protected virtual void update_state (bool first_update = false) {
            update_action ();
        }

        protected void update_action () {
            action_button.can_purchase = payments_enabled;
            action_button.allow_free = true;
            if (payments_enabled) {
                action_button.amount = int.parse (this.package.get_suggested_amount ());
            }

            if (action_stack.get_child_by_name ("buttons") != null) {
                action_stack.visible_child_name = "buttons";
            }

            switch (package.state) {
                case AppCenterCore.Package.State.NOT_INSTALLED:
#if PAYMENTS
                    action_button.label = _("Free");
#else
                    action_button.label = _("Install");
#endif
                    if (package.component.get_id () in settings.paid_apps) {
                        action_button.amount = 0;
                    }

                    set_stack_visibility (uninstall_button_stack, false);
                    set_stack_visibility (action_button_stack, !package.is_os_updates);
                    set_stack_visibility (open_button_stack, false);

                    break;
                case AppCenterCore.Package.State.INSTALLED:
                    set_stack_visibility (uninstall_button_stack, show_uninstall && !is_os_updates && !package.is_compulsory);
                    set_stack_visibility (action_button_stack, package.should_pay && updates_view);
                    set_stack_visibility (open_button_stack, show_open && package.get_can_launch ());

                    action_button.allow_free = false;
                    break;
                case AppCenterCore.Package.State.UPDATE_AVAILABLE:
                    if (!package.should_nag_update) {
                       action_button.amount = 0;
                    }

                    action_button.label = _("Update");

                    set_stack_visibility (uninstall_button_stack, show_uninstall && !is_os_updates && !package.is_compulsory);
                    set_stack_visibility (action_button_stack, true);
                    set_stack_visibility (open_button_stack, false);

                    break;
                case AppCenterCore.Package.State.INSTALLING:
                case AppCenterCore.Package.State.UPDATING:
                case AppCenterCore.Package.State.REMOVING:

                    action_stack.set_visible_child_name ("progress");
                    break;

                default:
                    critical ("Unrecognised package state %s", package.state.to_string ());
                    break;
            }
        }

        protected void update_progress () {
            Idle.add (() => {
                progress_bar.fraction = package.progress;
                return GLib.Source.REMOVE;
            });
        }

        protected virtual void update_progress_status () {
            Idle.add (() => {
                progress_bar.text = package.get_progress_description ();
                cancel_button.sensitive = package.change_information.can_cancel && !package.changes_finished;
                /* Ensure progress bar shows complete to match status (lp:1606902) */
                if (package.changes_finished) {
                    progress_bar.fraction = 1.0f;
                }

                return GLib.Source.REMOVE;
            });
        }

        private void action_cancelled () {
            action_cancellable.cancel ();
            update_action ();
            package.action_cancellable.cancel ();
        }

        private void launch_package_app () {
            try {
                package.launch ();
            } catch (Error e) {
                warning ("Failed to launch %s: %s".printf (package.get_name (), e.message));
            }
        }

        private async void action_clicked () {
            ActionResult result = 0;
            SourceFunc callback = action_clicked.callback;

            // Apply packagekit actions in the background, and ultimately yield a result
            // to this once the action is complete
            ThreadFunc<bool> run = () => {
                // Ensure that only one action is performed at a time.
                action_mutex.lock ();

                var loop = new MainLoop ();

                if (package.installed && !package.update_available) {
                    result = ActionResult.HIDE_BUTTON;
                } else if (package.update_available) {
                    package.update.begin ((obj, res) => {
                        package.update.end (res);
                        loop.quit ();
                    });
                } else {
                    package.install.begin ((obj, res) => {
                        if (package.update.end (res)) {
                            result = ActionResult.ADD_TO_INSTALLED_SCREEN;
                        }

                        loop.quit ();
                    });
                }

                if (action_cancellable.is_cancelled ()) {
                    package.action_cancellable.cancel ();
                    action_cancellable.reset ();
                    action_mutex.unlock ();
                    Idle.add ((owned)callback);
                    return true;
                }

                loop.run (); // wait for async methods above

                action_mutex.unlock ();
                Idle.add ((owned)callback);
                return true;
            };

            new Thread<bool> ("action_clicked", run);

            action_stack.set_visible_child_name ("progress");

            yield;

            switch (result) {
                case ActionResult.HIDE_BUTTON:
                    set_stack_visibility (action_button_stack, false);
                    break;
                case ActionResult.ADD_TO_INSTALLED_SCREEN:
                    // Add this app to the Installed Apps View
                    MainWindow.installed_view.add_app.begin (package);
                    break;
                default:
                    break;
            }
        }

        private async void uninstall_clicked () {
            if (yield package.uninstall ()) {
                // Remove this app from the Installed Apps View
                MainWindow.installed_view.remove_app.begin (package);
            }
        }
    }
}
