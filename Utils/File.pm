# Copyright 2019 Mike Cappella (mike@cappella.us)

package Utils::File;

our @ISA	= qw(Exporter);
our @EXPORT	= qw(file_exists slurp_fileX);

use v5.14;
use utf8;
use strict;
use warnings;
use diagnostics;

use Utils::Utils;

use if $^O eq 'MSWin32', 'Win32::Unicode::File';
# not used yet
#use if $^O eq 'MSWin32', 'Win32::Unicode::Dir';


sub slurp_fileX {
    my ($file, $encoding, $removebom) = @_;

    my $enc = '';
    if ($encoding and $encoding ne 'utf8' and $encoding !~ /^:/) {
	$enc = ":encoding($encoding)";
    }

    my ($ret, $fh);
    my $mode = myjoin('', "<", $enc);

    if ($^O eq 'MSWin32') {
	$fh = Win32::Unicode::File->new($mode, $file) or
	    bail "Unable to create instance of Win32::Unicode::File: $file\n$!";
	open $fh, $mode, $file or
	    bail "Unable to open file: $file\n$!";
	while (1) {
	    read $fh, my $buf, 4096;
	    last unless $buf;
	    $ret .= $buf;
	}
    }
    else {
	open $fh, $mode, $file or
	    bail "Unable to open file: $file\n$!";
	local $/;
	$ret = <$fh>;
    }

    Encode::_utf8_on($ret)		if $encoding and $encoding eq 'utf8';
    $ret =~ s/\A\N{BOM}//		if $removebom;

    close $fh;
    return $ret;
}

sub file_exists {
    local $_ = shift;
    return $^O eq 'MSWin32' ? file_type('e', $_) : -e $_;
}

1;
