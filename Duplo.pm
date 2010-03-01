#!/usr/bin/perl
package Duplo;

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


sub new {
    return bless({}, shift)->_init(@_);
}

sub _init {
    my $self = shift
        or croak "No self in _init";
    my ($dbfile) = @_
        or croak "Usage:: Duplo->new(\$dbfile)";

    $self->{dbfile} = $dbfile;
    if ( !-f $dbfile ) {
        $self->initdb();
    }
    return $self;
}

sub scan {
    my ($self, $dir) = @_
        or croak "Usage: \$duplo->scan(\$path)";
    $self->{scandir} = $dir;
    find(sub { return $self->_wanted($@); }, $dir);
}

sub _wanted {
    my $self = shift
        or croak "No self in wanted";
    my $fn = shift
        or croak "No fn in wanted";
    my $st = stat $fn or do {
        carp "Failed to stat " . $File::Find::name . " : $!\n";
        return;
    };
    return if S_ISDIR($st->mode);
    my $dbh = $self->connect();
    my ($Path,$Name) = map($dbh->quote($_),($File::Find::dir, $fn));
    my $Size = $st->size;
    my $CreateTime = $st->ctime;
    my $ModTime = $st->mtime;
    my $ID = unpack('L', sha1($File::Find::name));
    $dbh->do(qq|INSERT INTO File (ID, Path, Name, Size, CreateTime, ModTime) VALUES ($ID, $Path, $Name, $Size, $CreateTime, $ModTime)|);
}


sub duplicates_in {
    my ($self, $path) = @_
        or croak 'Usage: $duplo->duplicates_in($path_to_dir)';
    my $dbh = $self->connect();
    $path = $dbh->quote($path);
    my $stm = $dbh->prepare(qq{
        SELECT F2.*
        FROM File F1
        JOIN File F2 ON 
            F2.Name=F1.Name
            AND F2.Size=F1.Size
            AND F2.ID != F1.ID
            AND F2.Checksum = F1.Checksum
        WHERE F1.Path = $path
        ORDER BY F2.Path
        });
    $stm->execute();
    my @dups = ();
    while (my $row = $stm->fetchrow_hashref()) {
        push @dups, $row;
    }
    $stm->finish();
    return \@dups;
}

sub duplicates_of {
    my ($self, $path) = @_
        or croak 'Usage: $duplo->duplicates_of($path_to_file)';
    my $dbh = $self->connect();
    $path = $dbh->quote($path);
    my $stm = $dbh->prepare(qq{
        SELECT F2.*
        FROM File F1
        JOIN File F2 ON 
            F2.Name=F1.Name
            AND F2.Size=F1.Size
            AND F2.ID != F1.ID 
        WHERE F1.Name = $path
        ORDER BY F2.Path
        });
    $stm->execute();
    my @dups = ();
    while (my $row = $stm->fetchrow_hashref()) {
        push @dups, $row;
    }
    $stm->finish();
    return \@dups;
}

sub duplicates {
    my $self = shift
        or croak "USAGE: \$duplo->duplicates()";
    my $dbh = $self->connect();

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
    my $self = shift
        or croak 'Usage: $duplo->checksum()';
    my $duplicates = shift
        or do { carp("checksum() called without args"); return; };
    my $dbh = $self->connect();
    $self->verbmsg("Creating checksums");
    for my $fn (sort keys %$duplicates) {
        for my $f (sort { $a->{Path} cmp $b->{Path} } @{$duplicates->{$fn}}) {
            next if $f->{Checksum};
            my $fullname = catfile($f->{Path}, $f->{Name});
            my ($sum,undef) = split /\s+/, qx{ md5sum -b "$fullname" };
            $self->verbmsg("$fullname $sum");
            $dbh->do(qq| UPDATE File SET Checksum = '$sum' WHERE ID = $f->{'ID'} |);
        }
        $dbh->commit();
    }
}

sub plan {
    my $self = shift
        or croak 'Usage: $duplo->plan()';
    my $dups = shift
        or do { carp("plan() called without args"); return; };
    my $dbh = $self->connect();

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
        print "## $fn\n";
        for my $d (sort @{$files{$fn}}) {
            print qq{rm "$d" \n};
        }
        print "#\n";
    }
    $stm->finish();
}


sub get_dirs {
    my $self = shift
        or croak 'Usage: $duplo->plan()';
    my $dbh = $self->connect();
    my $stm = $dbh->prepare(q{
        SELECT
        DISTINCT F1.Path
        FROM File F1
        JOIN File F2
            ON F2.Checksum = F1.Checksum
            AND F2.Name=F1.Name
            AND F2.ID != F1.ID
        ORDER BY F1.Path,F2.Path
        });
    $stm->execute();
    my @paths;
    while(my $row = $stm->fetchrow_arrayref) {
        push @paths, $row->[0];
    }
    $stm->finish();
    return \@paths;
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

sub connect {
    my $self = shift
        or croak;
    return $self->{dbh} if $self->{dbh};
    my $dbname = $self->{dbfile};
    $self->verbmsg("Connecting to $dbname");
    my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname","","",
        { AutoCommit => 0, PrintError => 1});
    $self->{dbh} = $dbh;
    return $dbh;
}

sub initdb {
    my ($self) = @_
        or croak;
    $self->verbmsg("Initializing database");
    my $dbh = $self->connect();
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


sub verbmsg {
    my $self = shift
        or return;
    $self->{VERBOSE} && print STDERR @_;
    $self->{VERBOSE} && print "\n";
}

1;
