package Flat::Schema;

use strict;
use warnings;

use Carp qw(croak);

our $VERSION = '0.01';

sub new {
    my ($class, %options) = @_;

    my $self = {
        options => { %options },
    };

    return bless $self, $class;
}

sub from_profile {
    my ($class, %args) = @_;

    if (!exists $args{profile}) {
        croak "from_profile(): missing required named argument: profile";
    }

    my $profile = $args{profile};
    if (ref($profile) ne 'HASH') {
        croak "from_profile(): profile must be a hash reference";
    }

    my $report_version = $profile->{report_version};
    if (!defined $report_version || $report_version !~ /\A\d+\z/) {
        croak "from_profile(): profile.report_version must be an integer";
    }
    if ($report_version < 1) {
        croak "from_profile(): unsupported profile.report_version ($report_version); must be >= 1";
    }

    # v1 contract: we require a column list in the profile report contract.
    # If Flat::Profile evolves, we will adapt using only public report fields.
    my $profile_columns = $profile->{columns};
    if (ref($profile_columns) ne 'ARRAY') {
        croak "from_profile(): profile.columns must be an array reference";
    }

    my $self = $class->new();
    my $schema = $self->_build_schema_from_profile($profile);

    # Optional wrapper object could exist later; for now we return the canonical structure.
    return $schema;
}

sub _build_schema_from_profile {
    my ($self, $profile) = @_;

    my $schema = {
        schema_version => 1,
        generator      => {
            name    => 'Flat::Schema',
            version => $VERSION,
        },
        profile => $self->_profile_meta_from_profile($profile),
        columns => $self->_columns_from_profile($profile),
        issues  => [],
    };

    return $schema;
}

sub _profile_meta_from_profile {
    my ($self, $profile) = @_;

    my %meta = (
        report_version => int($profile->{report_version}),
    );

    # Preserve null-policy fields if present in the profile report contract.
    # (Schema inherits Profile's null model verbatim; details are handled in later commits.)
    if (exists $profile->{null_empty}) {
        $meta{null_empty} = $profile->{null_empty} ? 1 : 0;
    }
    if (exists $profile->{null_tokens} && ref($profile->{null_tokens}) eq 'ARRAY') {
        $meta{null_tokens} = [ @{ $profile->{null_tokens} } ];
    }

    return \%meta;
}

sub _columns_from_profile {
    my ($self, $profile) = @_;

    my @columns_in = @{ $profile->{columns} };

    # Deterministic: always sort by index (0-based).
    @columns_in = sort {
        ($a->{index} // 0) <=> ($b->{index} // 0)
    } @columns_in;

    my @columns_out;
    for my $col (@columns_in) {
        if (ref($col) ne 'HASH') {
            croak "from_profile(): each element of profile.columns must be a hash reference";
        }

        if (!exists $col->{index} || !defined $col->{index} || $col->{index} !~ /\A\d+\z/) {
            croak "from_profile(): each column must have an integer index";
        }

        my $index = int($col->{index});

        # v1 canonical structure: name may be undef/null (no header).
        my $name = exists $col->{name} ? $col->{name} : undef;
        if (defined $name && ref($name) ne '') {
            croak "from_profile(): column.name must be a string or undef";
        }

        # Commit 2 scope: structure + determinism only.
        # Type/nullability inference and issues are implemented in later commits.
        my $type     = 'string';
        my $nullable = 1;

        my $rows_observed = 0;
        if (exists $col->{rows_observed} && defined $col->{rows_observed} && $col->{rows_observed} =~ /\A\d+\z/) {
            $rows_observed = int($col->{rows_observed});
        }

        my $null_count = 0;
        if (exists $col->{null_count} && defined $col->{null_count} && $col->{null_count} =~ /\A\d+\z/) {
            $null_count = int($col->{null_count});
        }

        my $provenance = {
            basis         => 'profile',
            rows_observed => $rows_observed,
            null_count    => $null_count,
            null_rate     => {
                num => $null_count,
                den => $rows_observed,
            },
        };

        my $out = {
            index      => $index,
            name       => $name,
            type       => $type,
            nullable   => $nullable ? 1 : 0,
            provenance => $provenance,
            issues     => [],     # always include for uniformity at column-level? NO (not in contract)
        };

        # NOTE: The canonical contract uses top-level issues only.
        # Remove accidental column issues key if present.
        delete $out->{issues};

        push @columns_out, $out;
    }

    return \@columns_out;
}

sub to_json {
    my ($self, %args) = @_;

    if (!exists $args{schema}) {
        croak "to_json(): missing required named argument: schema";
    }
    my $schema = $args{schema};

    return _encode_json($schema, []);
}

sub to_yaml {
    my ($self, %args) = @_;

    if (!exists $args{schema}) {
        croak "to_yaml(): missing required named argument: schema";
    }
    my $schema = $args{schema};

    return _encode_yaml($schema, 0, []);
}

sub _encode_json {
    my ($value, $path) = @_;

    if (!defined $value) {
        return 'null';
    }

    my $ref = ref($value);

    if ($ref eq '') {
        if ($value =~ /\A-?(?:0|[1-9]\d*)\z/) {
            return $value;
        }
        if ($value eq '0') {
            return '0';
        }
        if ($value eq '1') {
            return '1';
        }
        return _json_quote($value);
    }

    if ($ref eq 'ARRAY') {
        my @parts;
        for my $i (0 .. $#$value) {
            push @parts, _encode_json($value->[$i], [ @$path, $i ]);
        }
        return '[' . join(',', @parts) . ']';
    }

    if ($ref eq 'HASH') {
        my @keys = _ordered_keys_for_path($value, $path);
        my @parts;
        for my $k (@keys) {
            my $v = $value->{$k};
            push @parts, _json_quote($k) . ':' . _encode_json($v, [ @$path, $k ]);
        }
        return '{' . join(',', @parts) . '}';
    }

    croak "to_json(): unsupported reference type: $ref";
}

sub _json_quote {
    my ($s) = @_;

    $s =~ s/\\/\\\\/g;
    $s =~ s/\"/\\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/\f/\\f/g;
    $s =~ s/\b/\\b/g;

    # Control chars
    $s =~ s/([\x00-\x1f])/sprintf("\\u%04x", ord($1))/ge;

    return '"' . $s . '"';
}

sub _encode_yaml {
    my ($value, $indent, $path) = @_;

    my $sp = ' ' x $indent;

    if (!defined $value) {
        return "~\n";
    }

    my $ref = ref($value);

    if ($ref eq '') {
        if ($value =~ /\A-?(?:0|[1-9]\d*)\z/) {
            return $value . "\n";
        }
        if ($value eq '0') {
            return "false\n";
        }
        if ($value eq '1') {
            return "true\n";
        }
        return _yaml_quote($value) . "\n";
    }

    if ($ref eq 'ARRAY') {
        if (!@$value) {
            return "[]\n";
        }

        my $out = '';
        for my $i (0 .. $#$value) {
            my $item = $value->[$i];
            my $item_ref = ref($item);

            if (!defined $item || $item_ref eq '') {
                $out .= $sp . '- ' . _chomp_one_line(_encode_yaml($item, 0, [ @$path, $i ]));
            } else {
                $out .= $sp . "-\n";
                $out .= _indent_block(_encode_yaml($item, $indent + 2, [ @$path, $i ]), $indent + 2);
            }
        }
        return $out;
    }

    if ($ref eq 'HASH') {
        my @keys = _ordered_keys_for_path($value, $path);

        if (!@keys) {
            return "{}\n";
        }

        my $out = '';
        for my $k (@keys) {
            my $v = $value->{$k};
            my $v_ref = ref($v);

            if (!defined $v || $v_ref eq '') {
                $out .= $sp . $k . ': ' . _chomp_one_line(_encode_yaml($v, 0, [ @$path, $k ]));
            } else {
                $out .= $sp . $k . ":\n";
                $out .= _indent_block(_encode_yaml($v, $indent + 2, [ @$path, $k ]), $indent + 2);
            }
        }
        return $out;
    }

    croak "to_yaml(): unsupported reference type: $ref";
}

sub _yaml_quote {
    my ($s) = @_;
    $s =~ s/'/''/g;
    return "'" . $s . "'";
}

sub _indent_block {
    my ($text, $indent) = @_;
    my $sp = ' ' x $indent;

    $text =~ s/\A//;
    $text =~ s/^/$sp/gm;

    return $text;
}

sub _chomp_one_line {
    my ($s) = @_;
    $s =~ s/\n\z//;
    return $s . "\n";
}

sub _ordered_keys_for_path {
    my ($hash, $path) = @_;

    my %rank;

    # Top-level schema keys: fixed list + lex fallback.
    if (!@$path) {
        my @ordered = qw(
            schema_version
            generator
            profile
            source
            options
            columns
            issues
            notes
        );
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

    # Column hash keys.
    if (@$path >= 2 && $path->[0] eq 'columns' && $path->[1] =~ /\A\d+\z/) {
        my @ordered = qw(
            index
            name
            type
            nullable
            length
            values
            pattern
            overrides
            provenance
        );
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

    # Generator keys.
    if (@$path >= 1 && $path->[0] eq 'generator') {
        my @ordered = qw(name version);
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

    # Profile keys: keep stable essentials first, then lex.
    if (@$path >= 1 && $path->[0] eq 'profile') {
        my @ordered = qw(report_version null_empty null_tokens rows_profiled generated_by);
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

    # Provenance keys.
    if (@$path >= 3 && $path->[0] eq 'columns' && $path->[2] eq 'provenance') {
        my @ordered = qw(
            basis
            rows_observed
            null_count
            null_rate
            distinct_count
            min_length_observed
            max_length_observed
            overrides
        );
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

    # Null rate rational keys.
    if (@$path >= 4 && $path->[0] eq 'columns' && $path->[3] eq 'null_rate') {
        my @ordered = qw(num den);
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

    # Issues list elements.
    if (@$path >= 2 && $path->[0] eq 'issues' && $path->[1] =~ /\A\d+\z/) {
        my @ordered = qw(level code message column_index details);
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

    # Default: lexicographic keys.
    return sort keys %$hash;
}

sub _ranked_sort_keys {
    my ($hash, $rank) = @_;

    return sort {
        my $ra = exists $rank->{$a} ? $rank->{$a} : 1_000_000;
        my $rb = exists $rank->{$b} ? $rank->{$b} : 1_000_000;

        return $ra <=> $rb
            || $a cmp $b;
    } keys %$hash;
}

=pod

=head1 NAME

Flat::Schema - Deterministic schema contracts for flat files

=head1 SYNOPSIS

    use Flat::Schema;

    my $schema = Flat::Schema->from_profile(
        profile => $profile_report,
    );

    my $json = Flat::Schema->new()->to_json(schema => $schema);
    my $yaml = Flat::Schema->new()->to_yaml(schema => $schema);

=head1 DESCRIPTION

Flat::Schema consumes reports produced by L<Flat::Profile> and generates a
deterministic, inspectable schema contract describing what tabular data
B<should> look like.

The schema is a canonical Perl data structure (hashref + arrays) suitable for
JSON/YAML serialization and for downstream validation (see L<Flat::Validate>).

=head1 NOTE ABOUT VERSION 0.01

Version 0.01 establishes the public schema structure and deterministic
serialization. Type inference, nullability rules, issues taxonomy emission, and
user overrides are implemented in subsequent commits.

=head1 METHODS

=head2 from_profile

    my $schema = Flat::Schema->from_profile(
        profile => $profile_report,
    );

Consumes a Flat::Profile report and returns the canonical schema data structure.

=head2 to_json

    my $json = Flat::Schema->new()->to_json(schema => $schema);

Deterministically serializes the schema to JSON using canonical key ordering.

=head2 to_yaml

    my $yaml = Flat::Schema->new()->to_yaml(schema => $schema);

Deterministically serializes the schema to YAML using canonical key ordering.

=head1 AUTHOR

Sergio de Sousa <sergio@serso.com>

=head1 LICENSE

This library is free software; you may redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;

