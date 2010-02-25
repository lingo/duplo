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

    --verbose       	Verbose output
                        	{ $::verbose = 1; }
    ');

our $dir = $ARGV[0] || './';

my $create_table = ! -f $DBFile;

#print Dumper(\$opt);

$verbose && print STDERR "Connecting to dbfile '$DBFile'\n";
our $dbh = DBI->connect("dbi:SQLite:dbname=$DBFile","","",
    { AutoCommit => 0, PrintError => 1}
);

$create_table && initdb();

unless ($opt->{'--noscan'}) {
    $verbose && print STDERR "Scanning '$dir'\n";
    find(\&wanted, $dir);
    $dbh->commit();
}


$verbose && print STDERR "Seeking duplicates, via DB\n";

my $duplicates = dups();

unless ($opt->{'--no-checksum'}) {
    checksum($duplicates);
}
unless ($opt->{'--no-plan'}) {
    plan($duplicates);
}

#print_dups($duplicates);
$dbh->disconnect();

sub wanted {
    my $fn = $_;
    my $st = stat $fn or do {
        carp "Failed to stat " . $File::Find::name . " : $!\n";
        return;
    };
    return if S_ISDIR($st->mode);
    my ($Path,$Name) = map($dbh->quote($_),($File::Find::dir, $fn));
    my $Size = $st->size;
    my $CreateTime = $st->ctime;
    my $ModTime = $st->mtime;
    my $ID = unpack('L', sha1($File::Find::name));
    $dbh->do(qq|INSERT INTO File (ID, Path, Name, Size, CreateTime, ModTime) VALUES ($ID, $Path, $Name, $Size, $CreateTime, $ModTime)|);
}


sub dups {
    my $stm = $dbh->prepare(q|
        SELECT F1.*,F2.*
        FROM File F1
        JOIN File F2 ON 
            F2.Name=F1.Name
            AND F2.Size=F1.Size
            AND F2.ID != F1.ID 
        ORDER BY F1.Path,F2.Path
        |);
    $stm->execute();
    my %dups = ();
    while (my $row = $stm->fetchrow_hashref()) {
        $dups{$row->{Name}} ||= [];
        push @{$dups{$row->{Name}}}, $row;
    }
    $stm->finish();
    return \%dups;
}

sub checksum {
    my $duplicates = shift
        or do { carp("checksum() called without args"); return; };
    for my $fn (sort keys %$duplicates) {
        for my $f (sort { $a->{Path} cmp $b->{Path} } @{$duplicates->{$fn}}) {
            next if $f->{Checksum};
            my $fullname = catfile($f->{Path}, $f->{Name});
            my ($sum,undef) = split /\s+/, qx{ md5sum -b "$fullname" };
            $verbose && print "$fullname $sum\n";
            $dbh->do(qq| UPDATE File SET Checksum = '$sum' WHERE ID = $f->{'ID'} |);
        }
        $dbh->commit();
    }
}

sub plan {
    my $dups = shift
        or do { carp("plan() called without args"); return; };
    my $stm = $dbh->prepare(q{
        SELECT
        F1.Path||'/'||F1.Name AS File1,
        F2.Path||'/'||F2.Name AS File2
        FROM File F1
        JOIN File F2
            ON F2.Checksum = F1.Checksum
            AND F2.Name=F1.Name
            AND F2.ID > F1.ID
        GROUP BY F2.ID
        ORDER BY F1.Name,F1.Path,F2.Path;
        });
    $stm->execute();
    my %files = ();
    while(my $row = $stm->fetchrow_arrayref) {
        $files{$row->[0]} ||= [];
        push @{$files{$row->[0]}}, $row->[1];
    }
    for my $fn (sort keys %files) {
        for my $d (sort @{$files{$fn}}) {
            print "# $fn\n";
            print qq{ rm "$d" \n };
        }
    }
    $stm->finish();
}

sub print_dups {
    my $dups = shift
        or do { carp("print_dups() called without args"); return; };
    for my $fn (sort keys %$dups) {
        my $fdups = $dups->{$fn};
        for my $i (sort { $a->{Path} cmp $b->{Path}} @$fdups) {
            printf("%-16s\t%-60s\t%6s\t%8s\n", $fn, $i->{Path}, fdata($i));
        }
        print "\n";
    }
}

sub fdata {
    my $f = shift
        or do { carp("fdata() called without args"); return (); };
    return (
        format_bytes($f->{Size}),
        time2str('%Y-%m-%d %H:%M:%S',$f->{ModTime})
    );
}

sub initdb {
    $verbose && print STDERR "Initializing database\n";
    $dbh->do(q|
        CREATE TABLE File (
            ID LONG PRIMARY KEY,
            Path VARCHAR(255) NOT NULL,
            Name VARCHAR(255) NOT NULL,
            Size LONG NOT NULL,
            CreateTime TIMESTAMP NOT NULL,
            ModTime TIMESTAMP NOT NULL,
            Checksum CHAR(32) DEFAULT NULL
        )
    |);
    $dbh->do(q| CREATE INDEX FilePathIdx ON File (Path) |);
    $dbh->do(q| CREATE INDEX FileNameIdx ON File (Name) |);
    $dbh->do(q| CREATE INDEX FileSizeIdx ON File (Size) |);
    $dbh->do(q| CREATE INDEX FileChecksufIdx ON File (Checksum) |);
    croak $DBI::errstr if $dbh->err();
    $dbh->commit();
}
