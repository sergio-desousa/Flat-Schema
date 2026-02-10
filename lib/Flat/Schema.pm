package Flat::Schema;

use strict;
use warnings;

our $VERSION = '0.01';

=pod

=head1 NAME

Flat::Schema - Deterministic schema contracts for flat files

=head1 SYNOPSIS

    use Flat::Schema;

    my $schema = Flat::Schema->from_profile(
        profile => $profile_report,
    );

=head1 DESCRIPTION

Flat::Schema consumes reports produced by L<Flat::Profile> and generates a
deterministic, inspectable schema contract describing what tabular data
B<should> look like.

The generated schema is:

=over 4

=item *

Deterministic (identical input produces identical output)

=item *

Serializable (JSON / YAML safe)

=item *

Human-readable and machine-consumable

=item *

Designed for downstream validation (see L<Flat::Validate>)

=back

This module is part of the Flat::* series:

=over 4

=item *

L<Flat::Profile> — what the data looks like

=item *

B<Flat::Schema> — what the data should look like

=item *

L<Flat::Validate> — whether data conforms to the schema

=back

=head1 DESIGN PHILOSOPHY

=over 4

=item *

Explicit behavior over clever inference

=item *

Streaming-first ETL ergonomics

=item *

Real-world legacy data focus

=item *

Low human error, predictable workflows

=back

=head1 VERSIONING

This is version 0.01 of Flat::Schema.

The schema format is versioned independently from the module version.
Backward compatibility of the schema format is a primary design goal.

=head1 AUTHOR

Sergio de Sousa <sergio@serso.com>

=head1 LICENSE

This library is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
