#!/usr/bin/perl
use warnings;
use strict;
use File::Find;
use Carp;
use Data::Dumper;

use Digest::SHA qw(sha1);
use Fcntl ':mode';
use File::stat;
use File::Find;
use DBI;
use Getopt::Declare;
use Date::Format;
use Number::Bytes::Human qw( format_bytes );
use File::Spec::Functions;

use Duplo;

our $DBFile = './files.db';
our $scan = 1;
my $verbose = 1;

our $opt = Getopt::Declare->new(q'
    --db <DBFILE>   	Specify database file
                    	    {  $::DBFile = $DBFILE; }

    --noscan          	Disable scan first

    -c
    --sum
    --checksum      	Do checksums

    --dupsfor <NAME>	Look for duplicates of NAME

    --verbose       	Verbose output
                        	{ $::verbose = 1; }
    ');

our $dir = $ARGV[0] || './';

our $duplo = Duplo->new($DBFile);
$duplo->{VERBOSE} = 1;

unless ($opt->{'--noscan'}) {
    $verbose && print STDERR "Scanning '$dir'\n";
    $duplo->scan($dir);
}


$verbose && print STDERR "Seeking duplicates, via DB\n";

if ($opt->{'--dupsfor'}) {
    my $duplicates = $duplo->duplicates_of($opt->{'--dupsfor'});
    print Dumper(\$duplicates);
} else {
    my $duplicates = $duplo->duplicates();

    unless ($opt->{'--no-checksum'}) {
        $duplo->checksum($duplicates);
    }
    unless ($opt->{'--no-plan'}) {
        $duplo->plan($duplicates);
    }
}

