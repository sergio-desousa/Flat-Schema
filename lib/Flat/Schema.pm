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

    my $profile_columns = $profile->{columns};
    if (ref($profile_columns) ne 'ARRAY') {
        croak "from_profile(): profile.columns must be an array reference";
    }

    my $self = $class->new();
    return $self->_build_schema_from_profile($profile);
}

sub _build_schema_from_profile {
    my ($self, $profile) = @_;

    my $issues = [];

    my $columns = $self->_columns_from_profile($profile, $issues);

    # Nullability / null issues (v1) are based on Profile's null model and observed counts.
    _apply_nullability_and_null_issues($profile, $columns, $issues);

    my $schema = {
        schema_version => 1,
        generator      => {
            name    => 'Flat::Schema',
            version => $VERSION,
        },
        profile => $self->_profile_meta_from_profile($profile),
        columns => $columns,
        issues  => [],
    };

    $schema->{issues} = _sort_issues_deterministically($issues);

    return $schema;
}

sub _profile_meta_from_profile {
    my ($self, $profile) = @_;

    my %meta = (
        report_version => int($profile->{report_version}),
    );

    # Preserve null-policy fields if present in the profile report contract.
    if (exists $profile->{null_empty}) {
        $meta{null_empty} = $profile->{null_empty} ? 1 : 0;
    }
    if (exists $profile->{null_tokens} && ref($profile->{null_tokens}) eq 'ARRAY') {
        $meta{null_tokens} = [ @{ $profile->{null_tokens} } ];
    }

    # If Profile provides rows_profiled, retain it (useful for diagnostics).
    if (exists $profile->{rows_profiled} && defined $profile->{rows_profiled} && $profile->{rows_profiled} =~ /\A\d+\z/) {
        $meta{rows_profiled} = int($profile->{rows_profiled});
    }

    return \%meta;
}

sub _columns_from_profile {
    my ($self, $profile, $issues) = @_;

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

        my $name = exists $col->{name} ? $col->{name} : undef;
        if (defined $name && ref($name) ne '') {
            croak "from_profile(): column.name must be a string or undef";
        }

        my ($type, $type_issues) = _infer_type_from_column($col);

        for my $issue (@$type_issues) {
            $issue->{column_index} = $index;
            push @$issues, $issue;
        }

        my $rows_observed = 0;
        if (exists $col->{rows_observed} && defined $col->{rows_observed} && $col->{rows_observed} =~ /\A\d+\z/) {
            $rows_observed = int($col->{rows_observed});
        }

        my $null_count = 0;
        if (exists $col->{null_count} && defined $col->{null_count} && $col->{null_count} =~ /\A\d+\z/) {
            $null_count = int($col->{null_count});
        }

        my $out = {
            index      => $index,
            name       => $name,
            type       => $type,
            nullable   => 1,    # set properly in _apply_nullability_and_null_issues()
            provenance => {
                basis         => 'profile',
                rows_observed => $rows_observed,
                null_count    => $null_count,
                null_rate     => {
                    num => $null_count,
                    den => $rows_observed,
                },
            },
        };

        push @columns_out, $out;
    }

    return \@columns_out;
}

# ------------------------
# Nullability inference (v1)
# ------------------------

sub _apply_nullability_and_null_issues {
    my ($profile, $columns, $issues) = @_;

    # v1 rule: nullable = true iff null_count > 0 (based on Profile null model).
    # Edge: if rows_observed == 0, nullable is set true and we emit no_rows_profiled once.
    my $any_rows_observed = 0;

    for my $col (@$columns) {
        my $rows_observed = int($col->{provenance}{rows_observed} // 0);
        my $null_count    = int($col->{provenance}{null_count} // 0);

        if ($rows_observed > 0) {
            $any_rows_observed = 1;
        }

        if ($rows_observed == 0) {
            $col->{nullable} = 1;
            next;
        }

        $col->{nullable} = $null_count > 0 ? 1 : 0;

        # all-null column warning
        if ($null_count == $rows_observed) {
            push @$issues, {
                level        => 'warning',
                code         => 'all_null_column',
                message      => 'Column contains only null values in profiled rows',
                column_index => $col->{index},
                details      => {
                    null_count    => $null_count,
                    rows_observed => $rows_observed,
                },
            };
        }
    }

    my $rows_profiled = undef;
    if (exists $profile->{rows_profiled} && defined $profile->{rows_profiled} && $profile->{rows_profiled} =~ /\A\d+\z/) {
        $rows_profiled = int($profile->{rows_profiled});
    }

    my $no_rows = 0;
    if (defined $rows_profiled) {
        $no_rows = $rows_profiled == 0 ? 1 : 0;
    } else {
        # If Profile doesn't report rows_profiled, infer from per-column rows_observed.
        $no_rows = $any_rows_observed ? 0 : 1;
    }

    if ($no_rows) {
        push @$issues, {
            level        => 'warning',
            code         => 'no_rows_profiled',
            message      => 'Profile report indicates zero rows were profiled; schema inference is limited',
            column_index => undef,
        };
    }

    return;
}

# ------------------------
# Type inference (v1)
# ------------------------

sub _infer_type_from_column {
    my ($col) = @_;

    my $evidence = $col->{type_evidence};

    # No evidence → string
    if (!defined $evidence || ref($evidence) ne 'HASH' || !%$evidence) {
        return ('string', []);
    }

    my %counts = map {
        $_ => int($evidence->{$_} // 0)
    } qw(string integer number boolean date datetime);

    my @present = sort grep { $counts{$_} > 0 } keys %counts;

    if (!@present) {
        return ('string', []);
    }

    # Temporal vs non-temporal conflict
    my @temporal = grep { $_ eq 'date' || $_ eq 'datetime' } @present;
    my @other    = grep { $_ ne 'date' && $_ ne 'datetime' } @present;

    if (@temporal && @other) {
        return (
            'string',
            [
                {
                    level   => 'warning',
                    code    => 'temporal_conflict_widened_to_string',
                    message => 'Temporal and non-temporal values mixed; widened to string',
                    details => {
                        temporal_candidates => \@temporal,
                        other_candidates    => \@other,
                        chosen              => 'string',
                    },
                },
            ],
        );
    }

    # Temporal widening
    if (@temporal) {
        if (grep { $_ eq 'datetime' } @temporal) {
            if (@temporal > 1) {
                return (
                    'datetime',
                    [
                        {
                            level   => 'info',
                            code    => 'type_widened',
                            message => 'Date values widened to datetime',
                            details => {
                                from => 'date',
                                to   => 'datetime',
                            },
                        },
                    ],
                );
            }
            return ('datetime', []);
        }
        return ('date', []);
    }

    # Scalar widening chain
    my @order = qw(boolean integer number string);
    my %rank  = map { $order[$_] => $_ } 0 .. $#order;

    my $chosen = (sort { $rank{$a} <=> $rank{$b} } @present)[-1];

    if (@present > 1) {
        return (
            $chosen,
            [
                {
                    level   => 'warning',
                    code    => 'mixed_type_evidence',
                    message => 'Multiple scalar types observed; widened',
                    details => {
                        candidates => \@present,
                        chosen     => $chosen,
                    },
                },
            ],
        );
    }

    return ($chosen, []);
}

# ------------------------
# Issues ordering (deterministic)
# ------------------------

sub _sort_issues_deterministically {
    my ($issues) = @_;

    my %level_rank = (
        info    => 0,
        warning => 1,
    );

    my @sorted = sort {
        my $la = exists $a->{level} ? $a->{level} : 'warning';
        my $lb = exists $b->{level} ? $b->{level} : 'warning';

        my $ra = exists $level_rank{$la} ? $level_rank{$la} : 9;
        my $rb = exists $level_rank{$lb} ? $level_rank{$lb} : 9;

        return $ra <=> $rb
            || ($a->{code} // '') cmp ($b->{code} // '')
            || _cmp_column_index($a->{column_index}, $b->{column_index})
            || ($a->{message} // '') cmp ($b->{message} // '')
            || _stable_details_string($a->{details}) cmp _stable_details_string($b->{details});
    } @$issues;

    return \@sorted;
}

sub _cmp_column_index {
    my ($a, $b) = @_;

    my $a_is_undef = !defined $a;
    my $b_is_undef = !defined $b;

    if ($a_is_undef && $b_is_undef) {
        return 0;
    }
    if ($a_is_undef) {
        return 1;    # undef last
    }
    if ($b_is_undef) {
        return -1;
    }

    return int($a) <=> int($b);
}

sub _stable_details_string {
    my ($details) = @_;

    if (!defined $details) {
        return '';
    }
    if (ref($details) ne 'HASH') {
        return '';
    }

    my @keys = sort keys %$details;
    my @pairs;
    for my $k (@keys) {
        my $v = $details->{$k};
        if (!defined $v) {
            push @pairs, $k . '=';
        } elsif (ref($v) eq 'ARRAY') {
            push @pairs, $k . '=[' . join(',', @$v) . ']';
        } elsif (ref($v) eq 'HASH') {
            my @ik = sort keys %$v;
            my @ip;
            for my $ik (@ik) {
                my $iv = $v->{$ik};
                push @ip, $ik . '=' . (defined $iv ? $iv : '');
            }
            push @pairs, $k . '={' . join(',', @ip) . '}';
        } else {
            push @pairs, $k . '=' . $v;
        }
    }

    return join(';', @pairs);
}

# ------------------------
# Deterministic serialization
# ------------------------

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
    $s =~ s/\x08/\\b/g;    # backspace character

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

    if (@$path >= 1 && $path->[0] eq 'generator') {
        my @ordered = qw(name version);
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

    if (@$path >= 1 && $path->[0] eq 'profile') {
        my @ordered = qw(report_version null_empty null_tokens rows_profiled generated_by);
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

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

    if (@$path >= 4 && $path->[0] eq 'columns' && $path->[3] eq 'null_rate') {
        my @ordered = qw(num den);
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

    if (@$path >= 2 && $path->[0] eq 'issues' && $path->[1] =~ /\A\d+\z/) {
        my @ordered = qw(level code message column_index details);
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

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

=head1 STATUS

This distribution is under active development.

Current implementation milestones include deterministic serialization, v1 type
inference (based on profile evidence), and v1 nullability inference based on
Profile's null model and observed counts.

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
