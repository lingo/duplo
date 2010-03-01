#!/usr/bin/perl
package DuploUI;

use warnings;
use strict;

use Glib qw(TRUE FALSE);
use Gnome2;
use Gtk2::GladeXML;
use File::Spec::Functions qw/ catfile /;
#use Gtk2::Ex::Simple::List;
#use Gtk2::Gdk::Keysyms;
#use Class::Struct;
use Carp;
use Data::Dumper;
#use YAML;
use Duplo;
use Number::Bytes::Human qw( format_bytes );

use constant TVCOL_FILENAME => 0;
use constant IVCOL_LABEL => 0;
use constant IVCOL_IMAGE => 1;
use constant IVCOL_PATH => 2;

our $CANDELETE = 0;

sub new { 
    my ($class) = shift;
    return bless({}, $class)->_init(shift);
}

sub run {
    my $self = shift->new(shift); Gtk2->main;
}

sub _init {
    my $self = shift or confess("_init is NOT a class method -- should be called as \$obj->parsed_item");

    my $src = shift
        or die "Failed to load glade file, pass to new()\n";

    Gnome2::Program->init ('Duplo', '1.0');

    $self->{_gui} = Gtk2::GladeXML->new($src);
    $self->{_gui}->signal_autoconnect_from_package($self);
    $self->{statusctx} = $self->_w('statusbar')->get_context_id("DuploUI");

    my $tree = $self->_w('treeFolders');
    $tree->set_model(Gtk2::ListStore->new(qw[ Glib::String ]));
    tv_addcolumn($tree, 'Path', 'string');

    $self->{menu} = $self->initMenu();

    $self->{duplo} = Duplo->new('ext3photo.db');
    $self->updateFoldersTree();
    $self->updateDupsTree();
    return $self;
}


sub _w {
    my ($self, $name) = @_
        or croak;
    return $self->{_gui}->get_widget($name);
}

sub mainWindow {
    my ($self) = @_
        or croak;
    return $self->_w('appWindow');
}

#==-{ Signal handler methods }-================================================#

sub on_appWindow_delete_event {
    Gtk2->main_quit;
}

sub on_btnNewScan_clicked {
    my $self = shift;
    $self->updateDupsTree();
}

sub on_btnOpenDB_clicked {
    my $self = shift;
    my $dbfile = $self->choose_file('Choose DB File');
    $self->{duplo} = Duplo->new($dbfile);
    $self->updateDupsTree();
} 

sub on_treeview_row_activated {
    my $self = shift;
    my ($tree, $path, $col) = @_;
    my $model = $tree->get_model();
    print Dumper(\$tree);
    print Dumper(\$path);
    print Dumper(\$col);
    print Dumper(\$model);
    my $iter = $model->get_iter($path);
    my $value = $model->get($iter, TVCOL_FILENAME);
    print Dumper(\$value);
    return unless $value;

    my $icon = $self->_w('iconview1');
    my $store = $icon->get_model();
    unless($store) { $self->initIconview($icon); }

    $store = $icon->get_model();

    $self->_w('statusbar')->push($self->{statusctx}, "Loading duplicates for $value...");
    $self->busy();

    my $items = $self->{duplo}->duplicates_of($value);
    $store->clear();

    my $unknown = Gtk2::Stock->lookup('gtk-missing-image');
    my ($pix,$size,$text);
    for my $f (@$items) {
        $pix = undef;
        if ($f->{Name} =~ /\.(jpg|gif|png|bmp|ico)$/i) {
            $pix = Gtk2::Gdk::Pixbuf->new_from_file_at_scale(catfile($f->{Path}, $f->{Name}), 256, 256, 1);
        }
        $pix = $unknown unless $pix;
        $size = format_bytes($f->{Size});
        $text = qq( <b>$f->{Name}</b>\n$f->{Path}\n$size );
        $store->insert_with_values(-1, 0 => $text, 1 => $pix, 2 => catfile($f->{Path}, $f->{Name}));
        #$store->insert_with_values(-1, IVCOL_LABEL => $text, IVCOL_IMAGE => $pix, IVCOL_PATH => catfile($f->{Path}, $f->{Name}));
    }
    $self->_w('statusbar')->pop($self->{statusctx});
    $self->idle();
}

sub on_iconview1_button_press_event {
    my $self = shift;
    my ($icon, $event) = @_;
    return unless $event->button() == 3;
    my $model = $icon->get_model();
    my $path = $icon->get_path_at_pos($event->x, $event->y);
    $icon->unselect_all();
    $icon->select_path($path);
    my $iter = $model->get_iter($path);
    my $value = $model->get($iter, IVCOL_PATH);
    print Dumper($value);
    my $menu = $self->{menu};
    $menu->popup(undef, undef, undef, undef, $event->button, $event->time);
}


sub on_iconview1_item_activated {
    my $self = shift;
    my @files = $self->getSelectedPaths();
    $self->busy();
    for my $f (@files) {
        system("gthumb \"$f\" &");
    }
    $self->idle();
}

sub on_menuDelete_activate {
    my $self = shift;
    my @files = $self->getSelectedPaths();
    if ($self->confirm('rm ' . join("\n", @files))) {
        for my $f (@files) {
            if ($CANDELETE) {
                system('mv', '-b', $f, '/tmp/');
            }
        }
        $self->alert("Deleted.");
    }
}

sub on_menuHardlink_activate {
    my $self = shift;
    my @files = $self->getSelectedPaths();
    if ($self->confirm('ln ' . join("\n", @files))) {
        $self->alert("Linked.");
    }
}

sub on_treeFolders_row_activated {
    my ($self, $tree, $path, $col) = @_;
    my $model = $tree->get_model();
    my $iter = $model->get_iter($path);
    my $value = $model->get($iter, 0);
    print Dumper(\$value);
    return unless $value;
    $self->updateDupsTree($value);
}

#==-{ General utility methods }-================================================#

sub busy {
    my $self = shift;
    my $cur = Gtk2::Gdk::Cursor->new('watch');
    $self->mainWindow()->window->set_cursor($cur);
    $self->updateUI();
}

sub idle {
    my $self = shift;
    $self->mainWindow()->window->set_cursor(undef);
    $self->updateUI();
}
sub updateUI {
    while (Gtk2->events_pending) {
        Gtk2->main_iteration();
    }
}

sub getSelectedPaths {
    my $self = shift;
    my $icon = $self->_w('iconview1');
    my $model = $icon->get_model();
    my @paths = $icon->get_selected_items();
    my @files = ();
    for my $path (@paths) {
        my $iter = $model->get_iter($path);
        push @files, $model->get($iter, IVCOL_PATH);
    }
    return @files;
}

sub initMenu {
    my $self = shift;
    my ($menu) = $self->{_gui}->get_widget_prefix("iconMenu");
    return $menu;
}


sub initIconview {
    my ($self, $icon) = @_
        or croak;
    my $store = Gtk2::ListStore->new(qw( Glib::String Gtk2::Gdk::Pixbuf Glib::Scalar ));
    $icon->set_model($store);
    $icon->set_markup_column(IVCOL_LABEL);
    $icon->set_pixbuf_column(IVCOL_IMAGE);
}

sub initTree {
    my ($self, $tree) = @_
        or croak;

    my $store = Gtk2::ListStore->new(qw( Glib::String ));
    $tree->set_model($store);
    my $col = Gtk2::TreeViewColumn->new_with_attributes('Filename', Gtk2::CellRendererText->new(), text => TVCOL_FILENAME);
    $col->set_sizing('fixed');
    $tree->append_column($col);
    $tree->set_search_column(TVCOL_FILENAME);
}


sub updateFoldersTree {
    my ($self) = @_
        or croak;
    my $tree = $self->_w('treeFolders');
    my $store = $tree->get_model();
    $store->clear();
    my $dirs = $self->{duplo}->get_dirs();
    for my $dir (@$dirs) {
        $store->insert_with_values(-1, 0 => $dir);
    }
}

sub updateDupsTree {
    my ($self, $path) = @_
        or croak;
    unless($self->{duplo}) {
        $self->alert("Please first open a DB file");
        return;
    }
    my $tree = $self->_w('treeview');
    my $store = $tree->get_model();
    unless($store) { $self->initTree($tree); }
    $store = $tree->get_model();
    $store->clear();

    my $duplicates;
    if ($path) {
        $duplicates = $self->{duplo}->duplicates_in($path);
        for my $fn (sort @$duplicates) {
            $store->insert_with_values(-1, 0 => $fn->{Name});
        }
    } else {
        $duplicates = $self->{duplo}->duplicates();
        for my $fn (sort keys %$duplicates) {
            $store->insert_with_values(-1, 0 => $fn);
        }
    }
}

sub choose_file {
    my ($self, $prompt, $type) = @_
        or croak;
    $type ||= 'open';
    $prompt ||= 'Choose a file';
    my $fc = Gtk2::FileChooserDialog->new($prompt, $self->mainWindow(), $type, 'gtk-cancel' => 'cancel', 'gtk-ok' => 'ok');
    my $resp = $fc->run();
    my $choice = undef;
    if ($resp eq 'ok') {
        $choice = $fc->get_filename();
    }
    $fc->destroy();
    return $choice;
}


sub confirm {
    my $self = shift
        or croak;
    my $dialog = Gtk2::MessageDialog->new_with_markup ($self->mainWindow(),
        [qw/modal destroy-with-parent/],
        'question',
        'ok-cancel',
        @_
    );
    my $retval = $dialog->run();
    $dialog->destroy();
    return $retval eq 'ok';
}

sub alert {
    my $self = shift
        or croak;
    my $dialog = Gtk2::MessageDialog->new_with_markup ($self->mainWindow(),
        [qw/modal destroy-with-parent/],
        'info',
        'ok',
        @_
    );
    my $retval = $dialog->run();
    $dialog->destroy();
    return $retval;
}

# Add a column to a treeview
#   TreeView    $tree
#   string      $name
#   string      $type (string|int|boolean or one of the Gtk types)
#   hash        %attr
#                   cell_data_func  function to render cell if type is custom
#                   cell_data       passed to above function
#                   ...
#                   other attr are passed to Gtk2::TreeViewColumn->set();
sub tv_addcolumn {
    my ($tree, $name, $type, %attr) = @_;
    my @cols = $tree->get_columns();
    my $colID = $attr{colID} || @cols;
    delete $attr{colID};

    if ($type =~ /string|int|boolean/) {
        $type =~ s/([a-z])(.*)/Glib::\u$1$2/;
    } elsif ($type !~ /^Glib::/) {
        $type = 'Glib::Scalar';
    }

    my %render_attr = ( text => $colID );
    my $renderer = Gtk2::CellRendererText->new()
        or return -1;
    my $column = Gtk2::TreeViewColumn->new_with_attributes($name, $renderer, %render_attr);

    if ($type eq 'Glib::Scalar') {
        $column->set_cell_data_func($renderer, $attr{cell_data_func}, $attr{cell_data});
        delete $attr{cell_data_func};
        delete $attr{cell_data};
    }
    $column->set($_, $attr{$_}) for keys %attr;
    $column->set_sort_column_id($colID);
    $tree->append_column($column);
    return ($column, $colID);
}



1;

package main;
if ($ARGV[0] && $ARGV[0] =~ /DELETE/) {
    $DuploUI::CANDELETE = 1;
}
DuploUI->run('Duplo.glade');
