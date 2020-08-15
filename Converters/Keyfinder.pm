# Key Finder XML export converter
#
# Copyright 2016 Mike Cappella (mike@cappella.us)

package Converters::Keyfinder;

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

use XML::XPath;
use XML::XPath::XMLParser;

=pod

=encoding utf8

=head1 Key Finder converter module

=head2 Platforms

=over

=item B<macOS>: Initially tested with version 1.2.0.32

=item B<Windows>: N/A

=back

=head2 Description

Converts your exported Key Finder data to 1PIF for 1Password import.

=head2 Instructions

Launch Key Finder.

Export its database as an XML export file using the C<< File > Save > Save to XML (*.xml) >> menu item.
When the C<Save> dialog appears, enter the name B<pm_export.xml>.
Next, expand the dialog by pressing the downward triangle at the right of the C<Save As> field, select B<Desktop> from the sidebar,
and finally, press the C<Save> button.

You may now quit Key Finder.

=cut

# a list of title REs to skip
my @ignored_titles = (
    '^Apple Coreservices Appleidauthenticationinfo',
);

my %card_field_specs = (
    software =>			{ textname => undef, fields => [
	[ 'reg_code',		1, qr/^serial(?:number)?|licenseCode|regcode$/i, ],
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

sub do_init {
    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
	'opts'		=> [ ],
    };
}

sub do_import {
    my ($file, $imptypes) = @_;

    $_ = slurp_file($file);

    my (%Cards, %records);
    my $n = 1;

    my $xp = XML::XPath->new(xml => $_);
    my $dbnodes = $xp->find('//Key');
    foreach my $node ($dbnodes->get_nodelist) {
	my $scan_type = $node->getParentNode->getName();
	my $computer_name = $node->getParentNode->getParentNode->getAttribute('computerName');

	my $title = $node->getAttribute('NAME');
	next if grep { $title =~ qr/$_/ } @ignored_titles;

	my ($type, $value) = ($node->getAttribute('TYPE'), $node->getAttribute('VALUE'));
	debug "   $computer_name($scan_type):\ttitle; $title, type: $type, value: $value";

	$records{$title}{$type} = $value;
	$records{$title}{'SCANTYPE__'} = $scan_type;
	$records{$title}{'COMPUTER__'} = $computer_name;
    }

    for my $title (keys %records) {
	my (%cmeta, @fieldlist);

	$cmeta{'title'} = $title;

	debug "Card: ", $cmeta{'title'};

	for (keys %{$records{$title}}) {
	    push @fieldlist, [ $_, $records{$title}{$_}  ];
	    debug "\t\t$fieldlist[-1][0]: $fieldlist[-1][1]";
	}

	my $itype = find_card_type(\@fieldlist);

	# skip all types not specifically included in a supplied import types list
	next if defined $imptypes and (! exists $imptypes->{$itype});

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
    my $fieldlist = shift;
    my $type = 'software';

#    for $type (sort by_test_order keys %card_field_specs) {
#	for my $cfs (@{$card_field_specs{$type}{'fields'}}) {
#	    next unless $cfs->[CFS_TYPEHINT] and defined $cfs->[CFS_MATCHSTR];
#	    for (@$fieldlist) {
#		# type hint
#		if ($_->[0] =~ $cfs->[CFS_MATCHSTR]) {
#		    debug "\ttype detected as '$type' (key='$_->[0]')";
#		    return $type;
#		}
#	    }
#	}
#    }
#
#    # Use icon name as a hint at the card type, since it is the only other
#    # information available to suggest card type
#    if (exists $icons{$icon}) {
#	debug "\ttype detected as '$icons{$icon}' icon name = $icon";
#	return $icons{$icon};
#    }
#
#    $type = grep($_->[0] eq 'Password', @$fieldlist) ? 'login' : 'note';

    debug "\ttype defaulting to '$type'";
    return $type;
}

# sort logins as the last to check
sub by_test_order {
    return  1 if $a eq 'webacct';
    return -1 if $b eq 'webacct';
    return  1 if $a eq 'login';
    return -1 if $b eq 'login';
    $a cmp $b;
}

sub date2epoch {
    my $msecs = shift;
    return $msecs / 1000;
}

1;
