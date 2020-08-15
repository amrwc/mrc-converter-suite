# Safe in Cloud XML export converter
#
# Copyright 2014 Mike Cappella (mike@cappella.us)

package Converters::Safeincloud;

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

=head1 Safe in Cloud converter module

=head2 Platforms

=over

=item B<macOS>: Initially tested with version 1.6

=item B<Windows>: Initially tested with version 2.8

=back

=head2 Description

Converts your exported Safe in Cloud data to 1PIF for 1Password import.

=head2 Instructions

Launch Safe in Cloud.

Export its database to an XML file using the C<< File > Export > As XML >> menu.
Navigate to your B<Desktop> folder, and save the file with the name B<pm_export.txt> to your Desktop.

You may now quit Safe in Cloud.

=cut

# Icon name to card type mapping, to help find_card_type determine card type.
my %icons;

my %card_field_specs = (
    code =>			{ textname => undef, icon => 'lock', type_out => 'note', fields => [
	[ 'password',		1, qr/^Code$/, 	{ custfield => [ $Utils::PIF::sn_main, $Utils::PIF::k_concealed, 'code', 'generate'=>'off' ] }],
    ]},
    creditcard =>		{ textname => undef, icon => 'credit_card', fields => [
	[ 'ccnum',		0, qr/^Number$/, ],
	[ 'cardholder',		2, qr/^Owner$/, ],
	[ '_expiry',		0, qr/^Expires$/, ],
	[ 'cvv',		2, qr/^CVV$/, ],
	[ 'pin',		0, qr/^PIN$/, ],
	[ 'cc_blocking',	2, qr/^Blocking$/, ],
    ]},
    email =>			{ textname => undef, icon => 'email', type_out => 'login', fields => [
	[ 'username',		3, qr/^Email$/, ],
	[ 'password',		3, qr/^Password$/, ],
	[ 'url',		3, qr/^Website$/, ],
    ]},
    passport =>			{ textname => undef,  icon => 'id', fields => [
	[ 'number',		0, qr/^Number$/, ],
	[ 'fullname',		0, qr/^Name$/, ],
	[ '_birthdate',		1, qr/^Birthday$/, ],
	[ '_issue_date',	1, qr/^Issued$/, ],
	[ '_expiry_date',	0, qr/^Expires$/, ],
    ]},
    insurance =>		{ textname => undef,  icon => 'insurance', type_out => 'membership', fields => [
	[ 'membership_no',	3, qr/^Number$/, ],
	[ '_expiry',		3, qr/^Expires$/, ],
	[ 'phone',		3, qr/^Phone$/, ],
    ]},
    login =>			{ textname => undef,  fields => [
	[ 'username',		2, qr/^Login$/, ],
	[ 'password',		2, qr/^Password$/, ],
    ]},
    membership =>		{ textname => undef,  icon => 'membership', fields => [
	[ 'membership_no',	3, qr/^Number$/, ],
	[ 'pin',		3, qr/^Password$/, ],
	[ 'website',		3, qr/^Website$/, ],
	[ 'phone',		3, qr/^Phone$/, ],
    ]},
    note =>                     { textname => undef,  fields => [
    ]},
    webacct =>			{ textname => undef,  icon => 'web_site', type_out => 'login', fields => [
	[ 'username',		3, qr/^Login$/, ],
	[ 'password',		3, qr/^Password$/, ],
	[ 'url',		3, qr/^Website$/, ],
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

sub do_init {
    # grab any additional icon numbers from card_field_specs
    for (keys %card_field_specs) {
	$icons{$card_field_specs{$_}{'icon'}} = $_		if exists $card_field_specs{$_}{'icon'};
    }

    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
    };
}

sub do_import {
    my ($file, $imptypes) = @_;

    $_ = slurp_file($file);
    s!<br/>!\n!g;

    my %Cards;
    my $n = 1;

    my %labels;
    my $xp = XML::XPath->new(xml => $_);
    my $dbnodes = $xp->find('//database');
    foreach my $nodes ($dbnodes->get_nodelist) {
	my $labelnodes = $xp->find('label', $nodes);
	# get the label / label id mappings stored as $labels{id} = label;
	$labels{$_->getAttribute('id')} = $_->getAttribute('name')	foreach $labelnodes->get_nodelist;

	my $cardnodes = $xp->find('card', $nodes);
	foreach my $cardnode ($cardnodes->get_nodelist) {
	    my (%cmeta, @fieldlist);

	    next if defined $cardnode->getAttribute('template') and $cardnode->getAttribute('template') eq 'true';
	    $cmeta{'title'} = $cardnode->getAttribute('title');
	    debug "Card: ", $cmeta{'title'};

	    my $cardelements = $xp->find('field|label_id|notes', $cardnode);
	    foreach my $cardelement ($cardelements->get_nodelist) {
		if ($cardelement->getName() eq 'field') {
		    push @fieldlist, [ $cardelement->getAttribute('name'), $cardelement->string_value ];
		    debug "\t\t$fieldlist[-1][0]: $fieldlist[-1][1]";
		}
		elsif ($cardelement->getName() eq 'label_id') {
		    push @{$cmeta{'tags'}}, $labels{$cardelement->string_value};
		    debug "\t\tLabel: $cmeta{'tags'}[-1]";
		}
		elsif ($cardelement->getName() eq 'notes') {
		    $cmeta{'notes'}  = $cardelement->string_value;
		    debug "\t\tnotes: $cmeta{'notes'}";
		}
		else {
		    bail 'Unexpected XPath type encountered: ', $cardelement->getName();
		}
	    }

	    my $icon = $cardnode->getAttribute('symbol');
	    push @fieldlist, [ Color  => $cardnode->getAttribute('color') ];
	    push @{$cmeta{'tags'}}, 'Stared'	if $cardnode->getAttribute('star') eq 'true';
	    $cmeta{'modified'} = date2epoch($cardnode->getAttribute('time_stamp'))	unless $main::opts{'notimestamps'};

	    my $itype = find_card_type(\@fieldlist, $icon);

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
    my $icon = shift;
    my $type;

    for $type (sort by_test_order keys %card_field_specs) {
	my ($nfound, @found);
	for my $cfs (@{$card_field_specs{$type}{'fields'}}) {
	    next unless $cfs->[CFS_TYPEHINT] and defined $cfs->[CFS_MATCHSTR];
	    for (@$fieldlist) {
		# type hint, requires matching the specified number of fields
		if ($_->[0] =~ $cfs->[CFS_MATCHSTR]) {
		    $nfound++;
		    push @found, $_->[0];
		    if ($nfound == $cfs->[CFS_TYPEHINT]) {
			debug sprintf "type detected as '%s' (%s: %s)", $type, pluralize('key', scalar @found), join('; ', @found);
			return $type;
		    }
		}
	    }
	}
    }

    # Use icon name as a hint at the card type, since it is the only other
    # information available to suggest card type
    if (exists $icons{$icon}) {
	debug "\ttype detected as '$icons{$icon}' icon name = $icon";
	return $icons{$icon};
    }

    $type = grep($_->[0] eq 'Password', @$fieldlist) ? 'login' : 'note';

    debug "\ttype defaulting to '$type'";
    return $type;
}

# sort logins as the last to check
sub by_test_order {
    return  1 if $a eq 'login';
    return -1 if $b eq 'login';
    return  1 if $a eq 'webacct';
    return -1 if $b eq 'webacct';
    $a cmp $b;
}

sub date2epoch {
    my $msecs = shift;
    return $msecs / 1000;
}

1;
