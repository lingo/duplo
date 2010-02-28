#!/usr/bin/perl
package Duplo;

use warnings;
use strict;

use Glib qw(TRUE FALSE);
use Gnome2;
use Gtk2::GladeXML;
#use Gtk2::Ex::Simple::List;
#use Gtk2::Gdk::Keysyms;
#use Class::Struct;
use Carp;
use Data::Dumper;
#use YAML;

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

    return $self;
}


#==-{ Signal handler methods }-================================================#

sub on_appWindow_delete_event {
    Gtk2->main_quit;
}



package main;
Duplo->run('Duplo.glade');


