# Text File to Secure Notes converter
#
# Copyright 2015 Mike Cappella (mike@cappella.us)

package Converters::Txt2notes;

our @ISA 	= qw(Exporter);
our @EXPORT     = qw(do_init do_import do_export);
our @EXPORT_OK  = qw();

use v5.14;
use utf8;
use strict;
use warnings;
#use diagnostics;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use Utils::PIF;
use Utils::Utils;
use Utils::Normalize;

use Cwd;
use File::Spec;
use File::Type;
use File::Basename;

=pod

=encoding utf8

=head1 Text Files (to Secure Notes) converter module

=head2 Platforms

=over

=item B<macOS>: All OS versions supported by the converter suite

=item B<Windows>: All OS versions supported by the converter suite

=back

=head2 Description

Converts one or more text files from your system to 1PIF for 1Password import as Secure Notes.
Your files are not modified.

=head2 Instructions

You may supply one or more file paths on the converter command line.
If you supply a directory name, its contents will be converted.
Sub-directories will be ignored unless you supply the C<--recurse> option.

=cut

my %card_field_specs = (
    note =>			{ textname => '', fields => [
	[ '_filename',		0, qr/^Filename$/, 		{ custfield => [ '', $Utils::PIF::k_string, 'original path' ] } ],
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

sub do_init {
    return {
	specs		=> \%card_field_specs,
	imptypes  	=> undef,
	filelist_ok	=> 1,
	opts		=> [ [ q{-r or --recurse	       # recurse into subdirectories },
			       'recurse|r' ],
			   ],
    }
}

sub do_import {
    my ($files, $imptypes) = @_;

    my %Cards;
    my ($n, $rownum) = (1, 1);
    my $itype = 'note';
    next if defined $imptypes and (! exists $imptypes->{$itype});

    my @filelist_expanded;
    my @filelist = ref($files) eq 'ARRAY' ? @$files : $files;

    while (@filelist) {
	my $path = shift @filelist;

	if (-d $path) {
	    my $dh;
	    unless (opendir($dh, $path)) {
		say "Unable to open directory. Skipping: $path: $!";
		next;
	    }
	    while (readdir($dh)) {
		next if /^\./;
		if (-d "$path/$_") {
		    # handle directory recursion - processed after files
		    push @filelist, "$path/$_"	if $main::opts{'recurse'};
		}
		else {
		    push @filelist_expanded, File::Spec->catfile($path, $_);
		}
	    }
	    closedir $dh;
	}
	else {
	    push @filelist_expanded, $path;
	}
    }

    my $ft = File::Type->new();

    for my $f (@filelist_expanded) {
	debug 'File: ', $f;
	my (%cmeta, @fieldlist, $io);

	if (! -e $f) {
	    say "Skipping non-existent file: $f";
	    next;
	}

	if ((stat $f)[7] >= 5 * 1024 * 1024) {
	    say "Skipping large file (> 5MB): $f";
	    next;
	}

	if ($ft->checktype_filename($f) ne 'application/octet-stream') {
	    say "Skipping non-text file: $f";
	    next;
	}

	$cmeta{'notes'} = slurp_file($f, 'utf8');
	if (!defined $cmeta{'notes'}) {
	    say "Unable to read text file. Skipping: $f: $!";
	    next;
	}

	if ($cmeta{'notes'} =~ /\A\s*\z/ms) {
	    say "Skipping all whitespace file: $f";
	    next;
	}

	if ($ft->checktype_contents($cmeta{'notes'}) ne 'application/octet-stream') {
	    say "Skipping non-text file: $f";
	    next;
	}

	$cmeta{'title'} = basename $f;

	push @fieldlist, [ 'Filename' => Cwd::abs_path($f) ];

	my $normalized = normalize_card_data(\%card_field_specs, $itype, \@fieldlist, \%cmeta);
	my $cardlist   = explode_normalized($itype, $normalized);

	for (keys %$cardlist) {
	    print_record($cardlist->{$_});
	    push @{$Cards{$_}}, $cardlist->{$_};
	}
	$n++;
    }

    summarize_import([ 'text file', 'item' ], $n - 1);
    return \%Cards;
}

sub do_export {
    add_custom_fields(\%card_field_specs);
    create_pif_file(@_);
}

1;
