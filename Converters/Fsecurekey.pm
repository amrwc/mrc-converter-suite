# F-Secure KEY JSON export converter
#
# Copyright 2015 Mike Cappella (mike@cappella.us)

package Converters::Fsecurekey;

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

use JSON::PP;

=pod

=encoding utf8

=head1 F-Secure KEY converter module

=head2 Platforms

=over

=item B<macOS>: Initially tested with version 4.0.108

=item B<Windows>: Initially tested with version 4.0.109

=back

=head2 Description

Converts your exported F-Secure KEY data to 1PIF for 1Password import.

=head2 Instructions

Launch F-Secure KEY.

Export its database to a text file.
Click C<Settings> in the sidebar, and then click C<Export passwords> in the Settings pane.
Click the C<Export> button, and save the file with the name B<pm_export.txt> to your Desktop.

You may now quit F-Secure KEY.

=cut

$DB::single = 1;					# triggers breakpoint when debugging

my %card_field_specs = (
    password =>                 { textname => undef, type_out => 'login', fields => [
        [ 'url',		0, 'url', ],
        [ 'username',		0, 'username', ],
        [ 'password',		0, 'password', ],
    ]},
);

sub do_init {
    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
        'opts'          => [],
    };
}

sub do_import {
    my ($file, $imptypes) = @_;
    my %Cards;

    $_ = slurp_file($file);

    my $decoded = decode_json $_;

    my $n = 1;
    for my $key (keys %{$decoded->{'data'}}) {
	my $entry = $decoded->{'data'}{$key};

	my (%cmeta, @fieldlist);
	my $itype = find_card_type($entry);

	# skip all types not specifically included in a supplied import types list
	next if defined $imptypes and (! exists $imptypes->{$itype});

	$cmeta{'title'} = $entry->{'service'};
	$cmeta{'notes'} = $entry->{'notes'};

	for my $key (qw/username password url/) {
	    push @fieldlist, [ $key => $entry->{$key} ]	 if $entry->{$key} ne '';
	}

	my $normalized = normalize_card_data(\%card_field_specs, $itype, \@fieldlist, \%cmeta);
	my $cardlist   = explode_normalized($itype, $normalized);

	for (keys %$cardlist) {
	    print_record($cardlist->{$_});
	    push @{$Cards{$_}}, $cardlist->{$_};
	}
	$n++;
    }

    summarize_import('item', $n - 1);
    return \%Cards;
}

sub do_export {
    add_custom_fields(\%card_field_specs);
    create_pif_file(@_);
}

sub find_card_type {
    my $f = shift;

    my $type = grep( $f->{$_} ne '', qw/username password url/) ? 'password' : 'note';
    debug "\t\ttype detected as '$type'";
    return $type;
}
