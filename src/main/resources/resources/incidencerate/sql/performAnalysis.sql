select cohort_id, is_outcome
into #cohorts
FROM (
  @cohortInserts
) C
;

select t.cohort_id as target_id, o.cohort_id as outcome_id
into #cteCohortCombos
FROM #cohorts t
CROSS JOIN #cohorts o
where t.is_outcome = 0 and o.is_outcome = 1;

select combos.target_id, combos.outcome_id, t.subject_id, t.cohort_start_date, t.cohort_end_date, t.adjusted_start_date, t.adjusted_end_date, op.observation_period_start_date as op_start_date, op.observation_period_end_date as op_end_date
into #cteCohortData
from #cteCohortCombos combos
join (
  select cohort_definition_id, subject_id, cohort_start_date, cohort_end_date, @adjustedStart as adjusted_start_date, @adjustedEnd as adjusted_end_date
  FROM @temp_database_schema.@cohort_table
) t on t.cohort_definition_id = combos.target_id
join @cdm_database_schema.observation_period op on t.subject_id = op.person_id and t.cohort_start_date between op.observation_period_start_date and op.observation_period_end_date
left join (
  select cohort_definition_id, subject_id, min(cohort_start_date) as cohort_start_date
  from @temp_database_schema.@cohort_table
  GROUP BY cohort_definition_id, subject_id
) O on o.cohort_definition_id = combos.outcome_id
  and t.subject_id = o.subject_id
where (o.cohort_start_date is null or o.cohort_start_date > t.adjusted_start_date)
  and t.adjusted_start_date < t.adjusted_end_date
  and t.adjusted_start_date between op.observation_period_start_date and op.observation_period_end_date
  @cohortDataFilter;

select target_id, outcome_id, subject_id, cohort_start_date, followup_end, is_case
into #cteEndDates
FROM (
  select target_id, outcome_id, subject_id, cohort_start_date, followup_end, is_case, row_number() over (partition by target_id, outcome_id, subject_id, cohort_start_date order by followup_end asc, is_case desc) as RN
  FROM (
    select combos.target_id, combos.outcome_id, t.subject_id, t.cohort_start_date, t.op_end_date as followup_end, 0 as is_case
    from #cteCohortCombos combos
    join #cteCohortData t on combos.target_id = t.target_id and combos.outcome_id = t.outcome_id

    UNION
    select combos.target_id, combos.outcome_id, t.subject_id, t.cohort_start_date, t.adjusted_end_date as followup_end, 0 as is_case
    from #cteCohortCombos combos
    join #cteCohortData t on combos.target_id = t.target_id and combos.outcome_id = t.outcome_id

    UNION
    select combos.target_id, combos.outcome_id, t.subject_id, t.cohort_start_date, o.cohort_start_date as followup_end, 1 as is_case
    from #cteCohortCombos combos
    join #cteCohortData t on combos.target_id = t.target_id and combos.outcome_id = t.outcome_id
    join (
      select cohort_definition_id, subject_id, min(cohort_start_date) as cohort_start_date
      from @temp_database_schema.@cohort_table
      GROUP BY cohort_definition_id, subject_id
    ) O on o.cohort_definition_id = combos.outcome_id and t.subject_id = o.subject_id
    where o.cohort_start_date > t.adjusted_start_date

    @EndDateUnions

  ) RawData
) Result
WHERE Result.RN = 1;

select t.target_id, t.outcome_id, t.subject_id, t.cohort_start_date, t.cohort_end_date, datediff(d,t.adjusted_start_date, e.followup_end) as time_at_risk, e.is_case
into #cteRawData
from #cteCohortData t
join #cteEndDates e on t.target_id = e.target_id
  and t.outcome_id = e.outcome_id
  and t.subject_id = e.subject_id
  and t.cohort_start_date = e.cohort_start_date;

select target_id, outcome_id, subject_id, cohort_start_date, cohort_end_date, time_at_risk, is_case
INTO #time_at_risk
from #cteRawData;

-- from here, take all the people's person_id, start_date, end_date, create an 'events table'
CREATE TABLE #analysis_events (
  event_id BIGINT,
  person_id BIGINT,
  start_date DATE,
  end_date DATE,
  op_start_date DATE,
  op_end_date DATE,
  TARGET_CONCEPT_ID BIGINT,
  visit_occurrence_id BIGINT
);

INSERT INTO #analysis_events (event_id, person_id, start_date, end_date, op_start_date, op_end_date, TARGET_CONCEPT_ID, visit_occurrence_id)
select row_number() over (partition by P.person_id order by P.start_date) as event_id, P.person_id, P.start_date, P.end_date, P.op_start_date, P.op_end_date, CAST(NULL as bigint) as TARGET_CONCEPT_ID, CAST(NULL as bigint) as visit_occurrence_id
FROM
(
  select distinct T.subject_id as person_id, T.cohort_start_date as start_date, T.cohort_end_date as end_date, OP.observation_period_start_date as op_start_date, OP.observation_period_end_date as op_end_date
  from #time_at_risk T
  JOIN @cdm_database_schema.observation_period OP on T.subject_id = OP.person_id and T.cohort_start_date between OP.observation_period_start_date and OP.observation_period_end_date
) P
;

-- create the stratifiction set
@codesetQuery

create table #strataCohorts 
(
  strata_sequence int,
  person_id bigint,
  event_id bigint
)
;
@strataCohortInserts

-- join back the followup to the stratification and write to the results page.
DELETE FROM @results_database_schema.ir_analysis_result where analysis_id = @analysisId;

INSERT INTO @results_database_schema.ir_analysis_result (analysis_id, target_id, outcome_id, strata_mask, person_count, time_at_risk, cases)
select @analysisId as analysis_id, T.target_id, T.outcome_id, CAST(E.strata_mask AS bigint),
  COUNT(subject_id) as person_count, 
  CAST(ROUND(sum(1.0 * time_at_risk / 365.25),0) AS BIGINT) as time_at_risk,
  sum(is_case) as cases
from #time_at_risk T
JOIN (
  select E.event_id, E.person_id, E.start_date, E.end_date, SUM(coalesce(POWER(cast(2 as bigint), SC.strata_sequence), 0)) as strata_mask
  FROM #analysis_events E
  LEFT JOIN #strataCohorts SC on SC.person_id = E.person_id and SC.event_id = E.event_id
  group by E.event_id, E.person_id, E.start_date, E.end_date
) E on T.subject_id = E.person_id and T.cohort_start_date = E.start_date and T.cohort_end_date = E.end_date
GROUP BY T.target_id, T.outcome_id, E.strata_mask
;
-- note in the case of no stratification (no rows in strataCohorts temp table), everyone will have strata_mask of 0.

-- calculate the individual strata counts from the raw person data. Rows from #strataCohorts are used to find counts for each strata
delete from @results_database_schema.ir_analysis_strata_stats where analysis_id = @analysisId;
insert into @results_database_schema.ir_analysis_strata_stats (analysis_id, target_id, outcome_id, strata_sequence, person_count, time_at_risk, cases)
select irs.analysis_id, combos.target_id, combos.outcome_id, irs.strata_sequence, coalesce(T.person_count, 0) as person_count, CAST(coalesce(T.time_at_risk, 0) AS bigint) as time_at_risk, coalesce(T.cases, 0) as cases
from @results_database_schema.ir_strata irs
cross join (
  select t.cohort_id as target_id, o.cohort_id as outcome_id
  FROM #cohorts t
  CROSS JOIN #cohorts o
  where t.is_outcome = 0 and o.is_outcome = 1 
) combos
left join
(
  select T.target_id, T.outcome_id, S.strata_sequence, count(S.event_id) as person_count, sum(1.0 * T.time_at_risk / 365.25) as time_at_risk, sum(T.is_case) as cases
  from #analysis_events E
  JOIN #strataCohorts S on S.person_id = E.person_id and E.event_id = S.event_id
  join #time_at_risk T on T.subject_id = E.person_id and T.cohort_start_date = E.start_date and T.cohort_end_date = E.end_date
  group by T.target_id, T.outcome_id, S.strata_sequence
) T on irs.strata_sequence = T.strata_sequence and T.target_id = combos.target_id and T.outcome_id = combos.outcome_id
WHERE irs.analysis_id = @analysisId
;

-- calculate distributions for TAR and TTO by strata

DELETE FROM @results_database_schema.ir_analysis_dist where analysis_id = @analysisId;

TRUNCATE TABLE #Codesets;
DROP TABLE #Codesets;

TRUNCATE TABLE #strataCohorts;
DROP TABLE #strataCohorts;

DROP TABLE #time_at_risk;
DROP TABLE #cteRawData;
DROP TABLE #cteEndDates;
DROP TABLE #cteCohortData;
DROP TABLE #cteCohortCombos;

DROP TABLE #cohorts;
DROP TABLE #analysis_events;