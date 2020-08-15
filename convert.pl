#!/usr/bin/perl

#
# Copyright 2014 Mike Cappella (mike@cappella.us)

use v5.14;
use utf8;
use strict;
use warnings;
#use diagnostics;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use FindBin qw($Bin);
use lib ("$Bin/.", "$Bin/lib");

use Utils::PIF;
use Utils::Utils;
use Getopt::Long;
use File::Basename;
#use Data::Dumper;

# Set the windows code page to handle UTF-8.  Use Lucida font.
use if $^O eq 'MSWin32', 'Win32::Console';
Win32::Console::OutputCP(65001)	if $^O eq 'MSWin32';

our $progstr = basename($0);

my @save_ARGV = @ARGV;
our %opts = (
    outfile => join($^O eq 'MSWin32' ? '\\' : '/', $^O eq 'MSWin32' ? $ENV{'USERPROFILE'} : $ENV{'HOME'}, 'Desktop', '1P_import'),
    folders => 0,			# folder creation is disabled by default
); 

my @converters = sort map {s/Converters\/(.*)\.pm$/$1/; lc $_} glob "Converters/*.pm";
my @candidates;
my ($module, $module_name);
our $converter;

# Peek to find the converter name, and load the module when found.
# Converter name may be missing when --help is used.
for (my $i = 0; $i < @ARGV; $i++) {
    next unless $ARGV[$i] =~ /^[a-z\d]+$/i;					# skip options, paths, etc.

    if (@candidates = grep { lc $ARGV[$i] eq $_ } @converters) {
	bail "Too man matching converters!  @candidates"	if @candidates > 1;
	splice @ARGV, $i, 1;
	$module_name = shift @candidates;
	$module = "Converters::" . ucfirst $module_name;
	eval {
	    (my $file = $module) =~ s|::|/|g;
	    require $file . '.pm';
	    $module->import();
	    1;
	} or do {
	    my $error = $@;
	    Usage(1, "Error: failed to load converter module '$module_name'\n$error");
	};

	# Initialize the converter
	$converter = $module->do_init()			if $module;;
	last;
    }
}

my @opt_config = (
    [ q{-d or --debug              # enable debug output},
	'debug|d'	=> sub { debug_on() } ],
    [ q{-a or --addfields          # add non-stock fields as custom fields },
       'addfields|a' ],
    [ q{-c or --checkpass          # check for known breached passwords},
	'checkpass|c' ],
    [ q{-e or --exptypes <list>    # comma separated list of one or more export types from list below},
	'exptypes|e=s' ],
    [ q{-f or --folders            # create and assign items to folders},
	'folders|f' ],
    [ q{-h or --help               # output help and usage text},
	'help|h' ],
    [ q{-i or --imptypes <list>    # comma separated list of one or more import types from list below},
	'imptypes|i=s' ],
    [ q{      --notimestamps       # do not set record modified/creation timestamps},
	'notimestamps' ],
    [ q{-o or --outfile <ofile>    # use file named ofile.1pif as the output file},
	'outfile|o=s' ],
    [ q{-t or --tags <list>        # add one or more comma-separated tags to the record},
       'tags|t=s' ],
    [ q{-v or --verbose            # output operations more verbosely},
	'verbose|v'	=> sub { verbose_on() } ],
    [ q{      --info <type>        # get info about converters (for helper programs)},
	'info=s'	=> sub { getInfo($_[1]) } ],
    [ q{},
	'testmode' ],		# for output file comparison testing
);
{
    local $SIG{__WARN__} = sub { say "\n*** ", $_[0]; };
    Getopt::Long::Configure(qw/no_ignore_case bundling pass_through/);
    if (defined $converter and exists $converter->{'opts'}) {
	push @opt_config, @{$converter->{'opts'}};
    }
    GetOptions(\%opts, map { (@$_)[1..$#$_] } @opt_config)
	or Usage(1);
}

debug "Runninng script from '$Bin'";
debug "Command Line: @save_ARGV";

my (%supported_types, %supported_types_str);
if (! $converter and ! $opts{'help'}) {
    Usage(1, "Command line does specify a valid converter name.");
}

if ($converter) {
    for (keys %{$converter->{'specs'}}) {
	$supported_types{'imp'}{$_}++;
	$supported_types{'exp'}{$converter->{'specs'}{$_}{'type_out'} // $_}++;
    }
    for ($converter->{'imptypes'} // ()) {
	$supported_types{'imp'}{$_}++;
    }
    for (qw/imp exp/) {
	$supported_types{$_}{'note'}++;
	$supported_types_str{$_} = join ' ', sort keys %{$supported_types{$_}};
    }
}

my $filelist_ok = (exists $converter->{'filelist_ok'} and $converter->{'filelist_ok'} == 1);

$opts{'help'} and Usage(0);

@ARGV == 0 and not exists $converter->{'files'} and
    Usage(1, "Missing <export file> name - please specify the file to convert");

# add the 1pif suffix if it isn't already there.  The 'onepif' converter will override this.
$opts{'outfile'} .= ".1pif"	if not $opts{'outfile'} =~ /\.\w{3,4}$/i;
debug "Output file: ", $opts{'outfile'};

for my $impexp (qw/imp exp/) {
    if (exists $opts{$impexp . 'types'}) {
	my %t;
	for (split /\s*,\s*/, $opts{$impexp . 'types'}) {
	    unless (exists $supported_types{$impexp}{$_}) {
		Usage(1, "Invalid --type argument '$_'; see supported types.");
	    }
	    $t{$_}++;
	}
	$opts{$impexp . 'types'} = \%t;
    }
}

# Check that the export file exists, unless the converter doesn't require one
bail "The file '$ARGV[0]' does not exist."	if not exists $converter->{'files'} and ! -e $ARGV[0];

if (@ARGV > 1 and not $filelist_ok) {
    Usage (1, "The $module_name converter can only process a single file.",
		"Files specified were:", map { "\t$_" } @ARGV);
}

# debugging aid
if (debug_enabled()) {
    if (exists $converter->{'files'}) {
	print_fileinfo($_)		for ref($converter->{'files'}) eq 'ARRAY' ? @{$converter->{'files'}} : ($converter->{'files'});
    }
    else {
	print_fileinfo($ARGV[0])
    }
}

# import the PM's export data, and export the converted data
do_export(
    do_import(
	@ARGV > 1 ? \@ARGV : $ARGV[0],
	$opts{imptypes} // undef),
    $opts{'outfile'},
    $opts{'exptypes'} // undef
);

### end - functions below

sub Usage {
    my $exitcode = shift;

    local $,="\n";
    say @_;
    if ($module_name) {
	print "Usage: $progstr $module_name <options>";
	unless ($converter->{'files'}) {
	    print " <export file>";
	    print " ..."	if $filelist_ok;
	}
	print "\n";
    }
    else {
	print "Usage: $progstr <converter> <options>";
	print " <export file> ...";
	print "\n\n";
	say 'Supported Converters:',  map(' ' x 4 . $_, flow(\@converters, 90));
    }

    if (keys %$converter) {
	say '',
	    'Options:',
	    map(' ' x 4 . $_->[0], sort {$a->[1] cmp $b->[1]} grep ($_->[0] ne '', @opt_config)),
	    '',
	    'Supported import types:',
	    map(' ' x 4 . $_, flow($supported_types_str{'imp'}, 90)),
	    'Supported export types:',
	    map(' ' x 4 . $_, flow($supported_types_str{'exp'}, 90));
    }
    else {
	say '',
	    'Options:',
	    map(' ' x 4 . $_->[0], sort {$a->[1] cmp $b->[1]} grep ($_->[0] ne '', @opt_config));

	say "\nSelect one of the converters above and add it to the command line to see more\ncomplete options.  Example:";
	say "\n    perl $progstr ewallet --help\n";
    }

    exit $exitcode;
}

# Get information about converters
# Currently only returns a list of the converters supported on macOS as name::fullname, 
# for use by the macOSConvertHelper.
# Perhaps later other converter-specific info can be provided (such as the allowed conversion file count, type (file, folder, autodiscovered), etc.
# arg value can be: macos or windows
sub getInfo {
    my $arg = shift;

    my @converter_meta;
    my $suite_dir = $Bin;
    my $converters_dir = $suite_dir . "/Converters";

    opendir(DIR, $converters_dir)
	or die "cannot open Converters directory $converters_dir";

    my @converters = grep(/\.pm$/, readdir(DIR));
    foreach my $f (sort @converters) {
	my $file = "$converters_dir/$f";
	open (RES, $file) or
	    die "failed to open $file\n";
	my %cdata;
	while(<RES>){
	    chomp;

	    # =head1 RoboForm converter module
	    if (/^=head1 (.+) converter module/) {
		$cdata{'fullname'} = $1;
	    }

	    # =item B<macOS>: Initially tested with version 1.95
	    elsif (/^=item B<macOS>:\s*(.*)$/) {
		$cdata{'macos'} = $1;
	    }

	    # =item B<Windows>: Initially tested with version 6.9.99 (see Notes)
	    elsif (/^=item B<Windows>:\s*(.*)$/) {
		$cdata{'windows'} = $1;
	    }
	    elsif (/^=cut/) {
		$cdata{'name'} = lc $f =~ s/\.pm//r;
		push @converter_meta, { %cdata };
		last;
	    }
	}
    }

    for (@converter_meta) {
	next if $arg eq 'macos'   and $_->{'macos'}   =~ m#N/A#;
	next if $arg eq 'windows' and $_->{'windows'} =~ m#N/A#;
	say "$_->{'name'}::$_->{'fullname'}";
    }
    exit 0;
}
1;
