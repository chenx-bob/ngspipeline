package CO::FastQ::Trim;

use strict;


=pod

=head1 NAME

CO::FastQ::Trim - Providing trimming methods for CO::FastQ::Read class

=head1 SYNOPSIS

  use CO::FastQ::Read;
  
  my $read = CO::FastQ::Read->new{line1 => \"\@read1",
                                  line2 => \"CGAGTCGTACGTAGTCGTAC",
                                  line3 => \"+",
                                  line4 => \"IIIIIIIIIIIIIIIIIIII",
                                  begin => 0,
                                  end => length("CGAGTCGTACGTAGTCGTAC")};
  
  $read->trim_ending_N;
  $read->trim_low_qual;
  $read->trim_ploy_A;

=head1 DESCRIPTION

Self defined trimming methods should be put here. These methods should return a
L<CO::FastQ::Read> object. Original sequence should not be modified. Only start
position and end position can be modified.

=head2 Subroutines
  
=cut



=pod

=over 4

=item C<CO::FastQ::Trim-E<gt>set(HASH)>

Setting global trimming parameters

=cut
our $MISMATCH_COUNT = 1;
our $MISMATCH_RATE_CUTOFF = 0.1;
our $TRIMMING_END = 0;

sub set {
	my $class = shift;
	
	my %param = (MISMATCH_COUNT => $MISMATCH_COUNT,
	             MISMATCH_RATE_CUTOFF => $MISMATCH_RATE_CUTOFF,
                 TRIMMING_END => $TRIMMING_END,
	             @_);
	             
	$MISMATCH_COUNT = $param{MISMATCH_COUNT};
	$MISMATCH_RATE_CUTOFF = $param{MISMATCH_RATE_CUTOFF};
	$TRIMMING_END = $param{TRIMMING_END};
}

=pod

=item C<$read-E<gt>trim_ending_N>

Trimming ending Ns on both side, experimental

=cut
sub trim_ending_N {
	my $read = shift; 
	
	my $seq = $read->seq;
	my $qual_str = $read->qual_str;
	
	# trimming ending N no matter how long they are
	my $O_TRIMMING_END = $TRIMMING_END;
	$TRIMMING_END = 1;
	
	my $trimmed = 0;
	$trimmed = $read->trim_by_base( 1, sub {$_[0] eq "N"});
	$trimmed = $read->trim_by_base(-1, sub {$_[0] eq "N"});

	$TRIMMING_END = $O_TRIMMING_END;

	return $read;
}

=pod

=item C<$read-E<gt>trim_ploy_A>

Trimming poly-A/T tail. First detect poly-A then poly-T. If poly-A on read end
are too short, they will not be trimmed.

=cut
sub trim_ploy_A {
	my $read = shift;

	# if continuous A/T at end are too short, they may not belong to poly-A/T
	my $O_TRIMMING_END = $TRIMMING_END;
	$TRIMMING_END = 0;

	my $trimmed1 = $read->trim_by_base( 1, sub {$_[0] eq "A"});
	my $trimmed2 = $read->trim_by_base(-1, sub {$_[0] eq "A"});
	
	# if poly-A is trimmed, we will not go on to look at poly-T
	my $trimmed3 = $read->trim_by_base( 1, sub {$_[0] eq "T"}) unless($trimmed1 or $trimmed2);
	my $trimmed4 = $read->trim_by_base(-1, sub {$_[0] eq "T"}) unless($trimmed2 or $trimmed2);

	$TRIMMING_END = $O_TRIMMING_END;

	return $read;
}

=pod

=item C<$read-E<gt>trim_low_qual($cutoff, $base)>

Trimming lwo quality bases on both ends. C<$base> is 33 by default. experimental

=cut
sub trim_low_qual {
	my $read = shift; 
	my $cutoff = shift;
	my $base = shift;
	
	my $O_TRIMMING_END = $TRIMMING_END;
	$TRIMMING_END = 1;
	
	# trimming low quanlity end no matter how long they are
	my $trimmed1 = $read->trim_by_base( 1, sub {ord($_[1]) - $base < $cutoff});
	my $trimmed2 = $read->trim_by_base(-1, sub {ord($_[1]) - $base < $cutoff});
	
	$TRIMMING_END = $O_TRIMMING_END;

	return $read;
}

# general trimming subroutine
#
# $_[0]: right to left (-1), left to right (else)
# $_[1]: subroutine to test whether it is a match of the base.
#        First parameter is current base, second parameter is current quality (ascii letter).
#        Subroutine returns TRUE if it is a match and those matches would be trimmed.
#
# In the subroutine, you do not need to consider the direction of base reading, i.e. left to
# right or right or left. Just from start to end.
sub trim_by_base {
	my $read = shift;
	my $direction = shift; # 1 | -1
	my $sub = shift;
	
	my $c;
	my $q;
	my $r;
	
	my $seq = $read->seq,
	my $qual_str = $read->qual_str;
	my $length = $read->length;
	
	# first read first 5 letters, at most contain one other letter
	my $i_mismatch = 0;
	my $last_match_pos = -1;
	for(my $i = 0; $i < 5 && $i < $length; $i ++) {
		
		$c = substr($seq,      ($direction > 0 ? $i : -$i-1), 1);
		$q = substr($qual_str, ($direction > 0 ? $i : -$i-1), 1);
		
		if( ! $sub->($c, $q) ) {
			$i_mismatch ++;
			
		} else {
			$last_match_pos = $i;
		}

	}
	
	# guess this may be a poly-N tail, then read forward
	if($i_mismatch <= $MISMATCH_COUNT) {
	
		for(my $i = 5; $i < $length; $i ++) {
			$c = substr($seq,      ($direction > 0 ? $i : -$i-1), 1);
			$q = substr($qual_str, ($direction > 0 ? $i : -$i-1), 1);
			
			if(! $sub->($c, $q)) {
				$i_mismatch ++;
				
				$r = mismatch_rate($i_mismatch, $i + 1);
				if($r > $MISMATCH_RATE_CUTOFF) {
					#print STDERR "$i, $c, $q, $last_match_pos\n";

					# read 10 letters more
					my $tmp_last_match_pos = $last_match_pos;
					my $j;
					my $extend = 10;
					for($j = $i + 1; $j < $i + 1+$extend && $i < $length; $j ++) {
						
						$c = substr($seq,      ($direction > 0 ? $j : -$j-1), 1);
						$q = substr($qual_str, ($direction > 0 ? $j : -$j-1), 1);
						
						if( ! $sub->($c, $q) ) {
							$i_mismatch ++;
						} else {
							$tmp_last_match_pos = $j;
						}
						#print STDERR "$j, $c, $q, $tmp_last_match_pos, extending\n";
						# if mismatch rate drop down from cutoff, keep on reading
						$r = mismatch_rate($i_mismatch, $j + 1);
						if($r <= $MISMATCH_RATE_CUTOFF) {
							$i = $j;
							last;
						}
					}
					
					if($j == $i + 1+$extend or $j == $length) {
						$read->set_end_pos($direction, $last_match_pos);
						return 1;
					} else {
						$last_match_pos = $tmp_last_match_pos;
					}
				}
			} else {
				$last_match_pos = $i;
			}
			#print STDERR "$i, $c, $q, $last_match_pos\n";
		}
	
	} else {
		if($TRIMMING_END) {
			$read->set_end_pos($direction, $last_match_pos);
			return 1;
		} else {
			return 0;
		}
	}
}

# how to calculate mismatch rate. By default, it is the ratio of mismatches
# and the whole sequence.
sub mismatch_rate {
	my $mismatch = shift;
	my $all = shift;
	
	return $mismatch/$all;
}

# calculate the real ending positions according to 'direction'
sub set_end_pos {
	my $read = shift;
	my $direction = shift;
	my $pos = shift;
	
	if($direction > 0) {
		$read->{begin} = $read->{begin} + $pos + 1;
	} else {
		$read->{end} = $read->{end} - $pos - 1;
	}
}


sub check_quality_percentage {
	my $read = shift; 
	my $cutoff = shift;
	my $base = shift;
	my $p = shift;
	
	my $qual = $read->qual($base);
	
	my $i_low_qual = 0;
	for (@$qual) {
		$_ < $cutoff ? $i_low_qual ++ : $i_low_qual;
	}
	
	$i_low_qual > 20 && $i_low_qual/scalar(@$qual) >= $p ? 0 : 1;
}

=pod

=back

=head1 AUTHOR

Zuguang Gu E<lt>z.gu@dkfz.deE<gt>

=cut

1;
