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

    my $overrides = undef;
    if (exists $args{overrides}) {
        $overrides = $args{overrides};
        if (defined $overrides && ref($overrides) ne 'ARRAY') {
            croak "from_profile(): overrides must be an array reference";
        }
    }

    my $self = $class->new();
    return $self->_build_schema_from_profile($profile, $overrides);
}

sub _build_schema_from_profile {
    my ($self, $profile, $overrides_in) = @_;

    my $issues = [];

    my $columns = $self->_columns_from_profile($profile, $issues);

    _apply_nullability_and_null_issues($profile, $columns, $issues);

    my $overrides_map = _normalize_overrides($overrides_in);
    _apply_overrides($columns, $overrides_map, $issues);

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

    if (exists $profile->{null_empty}) {
        $meta{null_empty} = $profile->{null_empty} ? 1 : 0;
    }
    if (exists $profile->{null_tokens} && ref($profile->{null_tokens}) eq 'ARRAY') {
        $meta{null_tokens} = [ @{ $profile->{null_tokens} } ];
    }

    if (exists $profile->{rows_profiled} && defined $profile->{rows_profiled} && $profile->{rows_profiled} =~ /\A\d+\z/) {
        $meta{rows_profiled} = int($profile->{rows_profiled});
    }

    return \%meta;
}

sub _columns_from_profile {
    my ($self, $profile, $issues) = @_;

    my @columns_in = @{ $profile->{columns} };

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
            nullable   => 1,
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
# Overrides (v1)
# ------------------------

sub _normalize_overrides {
    my ($overrides_in) = @_;

    if (!defined $overrides_in) {
        return {};
    }

    my %map;

    for my $entry (@$overrides_in) {
        if (ref($entry) ne 'HASH') {
            croak "from_profile(): each overrides entry must be a hash reference";
        }

        if (!exists $entry->{column_index} || !defined $entry->{column_index} || $entry->{column_index} !~ /\A\d+\z/) {
            croak "from_profile(): overrides entry missing integer column_index";
        }

        my $idx = int($entry->{column_index});

        if (!exists $entry->{set} || ref($entry->{set}) ne 'HASH') {
            croak "from_profile(): overrides entry missing set hash";
        }

        my %set = %{ $entry->{set} };

        my %allowed = map { $_ => 1 } qw(type nullable name length);
        for my $k (keys %set) {
            if (!$allowed{$k}) {
                croak "from_profile(): override field not supported in v1: $k";
            }
        }

        if (exists $set{type}) {
            if (!defined $set{type} || ref($set{type}) ne '') {
                croak "from_profile(): override type must be a string";
            }
        }

        if (exists $set{nullable}) {
            if (!defined $set{nullable} || ref($set{nullable}) ne '') {
                croak "from_profile(): override nullable must be a scalar boolean (0/1)";
            }
            $set{nullable} = $set{nullable} ? 1 : 0;
        }

        if (exists $set{name}) {
            if (defined $set{name} && ref($set{name}) ne '') {
                croak "from_profile(): override name must be a string or undef";
            }
        }

        if (exists $set{length}) {
            if (!defined $set{length} || ref($set{length}) ne 'HASH') {
                croak "from_profile(): override length must be a hash reference";
            }

            my %len = %{ $set{length} };
            my %len_allowed = map { $_ => 1 } qw(min max);

            for my $lk (keys %len) {
                if (!$len_allowed{$lk}) {
                    croak "from_profile(): override length supports only min/max";
                }
                if (defined $len{$lk} && $len{$lk} !~ /\A\d+\z/) {
                    croak "from_profile(): override length.$lk must be an integer";
                }
                $len{$lk} = int($len{$lk}) if defined $len{$lk};
            }

            $set{length} = \%len;
        }

        $map{$idx} = {} if !exists $map{$idx};
        for my $k (sort keys %set) {
            $map{$idx}{$k} = $set{$k};
        }
    }

    return \%map;
}

sub _apply_overrides {
    my ($columns, $overrides_map, $issues) = @_;

    return if !%$overrides_map;

    my %col_by_index = map { $_->{index} => $_ } @$columns;

    for my $idx (sort { $a <=> $b } keys %$overrides_map) {
        if (!exists $col_by_index{$idx}) {
            croak "from_profile(): override references unknown column_index $idx";
        }

        my $col = $col_by_index{$idx};
        my $set = $overrides_map->{$idx};

        my @fields_applied;

        for my $field (sort keys %$set) {
            my $override_value = $set->{$field};

            if ($field eq 'length') {
                my $inferred = exists $col->{length} ? $col->{length} : undef;
                my $different = _different_length($inferred, $override_value);

                if ($different) {
                    push @$issues, {
                        level        => 'warning',
                        code         => 'override_conflicts_with_profile',
                        message      => 'Override conflicts with inferred value',
                        column_index => $col->{index},
                        details      => {
                            field            => 'length',
                            overridden_value => _stable_details_string($override_value),
                            inferred_value   => _stable_details_string($inferred),
                        },
                    };
                }

                $col->{length} = { %{ $override_value } };
                _record_override($col, 'length', $override_value);

                push @fields_applied, 'length';
                next;
            }

            _override_scalar_field(
                col            => $col,
                field          => $field,
                override_value => $override_value,
                issues         => $issues,
            );

            push @fields_applied, $field;
        }

        if (@fields_applied) {
            my @sorted_fields = sort @fields_applied;

            push @$issues, {
                level        => 'info',
                code         => 'override_applied',
                message      => 'Overrides applied to column',
                column_index => $col->{index},
                details      => {
                    fields => \@sorted_fields,
                },
            };

            $col->{provenance}{overrides} = [ @sorted_fields ];
        }
    }

    return;
}

sub _different_length {
    my ($a, $b) = @_;

    if (!defined $a && !defined $b) {
        return 0;
    }
    if (!defined $a || !defined $b) {
        return 1;
    }
    if (ref($a) ne 'HASH' || ref($b) ne 'HASH') {
        return 1;
    }

    for my $k (qw(min max)) {
        my $av = exists $a->{$k} ? $a->{$k} : undef;
        my $bv = exists $b->{$k} ? $b->{$k} : undef;

        if ((defined $av) != (defined $bv)) {
            return 1;
        }
        if (defined $av && defined $bv && int($av) != int($bv)) {
            return 1;
        }
    }

    return 0;
}

sub _override_scalar_field {
    my (%args) = @_;

    my $col            = $args{col};
    my $field          = $args{field};
    my $override_value = $args{override_value};
    my $issues         = $args{issues};

    if ($field eq 'nullable') {
        $override_value = $override_value ? 1 : 0;
    }

    my $inferred_value = exists $col->{$field} ? $col->{$field} : undef;

    my $different = 0;
    if (!defined $inferred_value && !defined $override_value) {
        $different = 0;
    } elsif (!defined $inferred_value || !defined $override_value) {
        $different = 1;
    } else {
        $different = ($inferred_value ne $override_value) ? 1 : 0;
    }

    if ($different) {
        push @$issues, {
            level        => 'warning',
            code         => 'override_conflicts_with_profile',
            message      => 'Override conflicts with inferred value',
            column_index => $col->{index},
            details      => {
                field            => $field,
                overridden_value => defined $override_value ? $override_value : undef,
                inferred_value   => defined $inferred_value ? $inferred_value : undef,
            },
        };
    }

    $col->{$field} = $override_value;
    _record_override($col, $field, $override_value);

    return;
}

sub _record_override {
    my ($col, $field, $value) = @_;

    $col->{overrides} = {} if !exists $col->{overrides} || ref($col->{overrides}) ne 'HASH';

    if ($field eq 'length') {
        $col->{overrides}{length} = { %{ $value } };
        return;
    }

    $col->{overrides}{$field} = $value;

    return;
}

# ------------------------
# Type inference (v1)
# ------------------------

sub _infer_type_from_column {
    my ($col) = @_;

    my $evidence = $col->{type_evidence};

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
        return 1;
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

    if (ref($details) eq 'HASH') {
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

    if (ref($details) eq 'ARRAY') {
        return '[' . join(',', @$details) . ']';
    }

    return '' . $details;
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
    $s =~ s/\x08/\\b/g;

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

    if (@$path >= 3 && $path->[0] eq 'columns' && $path->[2] eq 'length') {
        my @ordered = qw(min max);
        @rank{@ordered} = (0 .. $#ordered);
        return _ranked_sort_keys($hash, \%rank);
    }

    if (@$path >= 3 && $path->[0] eq 'columns' && $path->[2] eq 'overrides') {
        my @ordered = qw(type nullable name length);
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
        overrides => [
            { column_index => 0, set => { type => 'integer', nullable => 0 } },
        ],
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

Implemented so far:

=over 4

=item *

Canonical schema structure (v1)

=item *

Deterministic JSON/YAML serialization

=item *

v1 type inference based on profile evidence

=item *

v1 nullability inference based on observed nulls

=item *

v1 user overrides (index-based) with audit trail and override issues

=back

=head1 METHODS

=head2 from_profile

    my $schema = Flat::Schema->from_profile(
        profile => $profile_report,
        overrides => [
            { column_index => 0, set => { type => 'string', nullable => 1 } },
        ],
    );

Consumes a Flat::Profile report and returns the canonical schema data structure.

Overrides are optional and are applied after inference. Conflicts between
inferred values and overrides are recorded as issues.

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
