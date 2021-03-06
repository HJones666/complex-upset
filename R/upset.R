names_of_true = function(row) {
  sanitized_names = c()
  for (name in names(which(row))) {
      if (grepl('-', name, fixed=TRUE)) {
          name = gsub('-', '_')
          if (name %in% names(which(row))) {
              stop('The group names contain a combination of minus characters (-) which could not be simplified; please remove those.')
          }
      }
      sanitized_names = c(sanitized_names, name)
  }
  paste(sanitized_names, collapse='-')
}


#' @export
compare_between_intersections = function(data, intersect, test=kruskal.test, tests=list(), ignore=list(), ...) {
  data = upset_data(data, intersect, ...)
  isect = data$intersected

  ignore = c('intersection', ignore)

  candidate_variables = setdiff(setdiff(names(isect), intersect), ignore)

  results = list()

  for (variable in candidate_variables) {

    if (variable %in% names(tests)) {
      var_test = tests[[variable]]
    } else {
      var_test = test
    }
    # TODO: there should be another test:
    #     varaible ~ group_1 + group_2 + ... + group_n
    #  to assess "dose effect"
    result = var_test(as.formula(paste(variable, '~ intersection')), data=isect)

    results[[length(results) + 1]] = list(
      variable=variable,
      p.value=result$p.value,
      statistic=result$statistic,
      test=result$method
    )
  }

  if (length(results) == 0) {
    headers = c('variable', 'p.value', 'statistic', 'test', 'fdr')
    results = data.frame(matrix(
      ncol=length(headers),
      nrow=0,
      dimnames=list(NULL, headers)
    ))
  } else {
    results = do.call(rbind, lapply(results, data.frame))
    results$fdr = p.adjust(results$p.value, 'BH')
    rownames(results) = results$variable
  }

  results
}


gather = function(data, idvar, col_name, value_name='value') {
    not_idvar = colnames(data)
    not_idvar = not_idvar[not_idvar != idvar]
    result <- stack(data, select=not_idvar)
    result$group <- rep(data[[idvar]], times=ncol(data) - 1)
    colnames(result) = c(value_name, col_name, idvar)
    result
}


compute_matrix = function(sorted_intersections, sorted_groups) {
    rows = c()
    for (group in sorted_groups) {
        row = c()
        for (intersection in sorted_intersections) {
            i_groups = unlist(strsplit(intersection, '-'))
            row = cbind(row, group %in% i_groups)
        }
        rows = rbind(rows, row)
    }

    matrix_data = as.data.frame(rows, row.names=sorted_groups)
    colnames(matrix_data) = sorted_intersections
    matrix_data
}


compute_unions = function(data, sorted_intersections) {
    rows = c()

    for (intersection in sorted_intersections) {
        i_groups = unlist(strsplit(intersection, '-'))
        union_for_intersection = data[data$group %in% i_groups, ]

        ids = union_for_intersection$id
        deduplicated = union_for_intersection[!duplicated(ids), ]

        # NOTE:
        # union: nrow(deduplicated)
        # sum of counts: nrow(union_for_intersection)
        rows = c(rows, nrow(deduplicated))
    }

    names(rows) = sorted_intersections
    rows
}


check_sort = function(
    sort_order,
    allowed = c('descending', 'ascending'),
    what = 'order'
) {

    if (sort_order == FALSE) {
        return()
    }

    if(!(sort_order %in% allowed)) {
        stop(
            paste0(
                'Sort ',
                what,
                ' has to be one of: ',
                paste(allowed, collapse=' or '),
                ', not "',
                sort_order,
                '""'

            )
        )
    }
}


get_sort_order = function(data, sort_order) {
    check_sort(sort_order)

    if (sort_order == 'descending') {
        order(data)
    } else {
        order(-data)
    }
}


count_occurrences = function(x, symbol) {
    lengths(regmatches(x, gregexpr(symbol, x)))
}


#' Prepare data for UpSet plots
#'
#' @param min_size minimal number of observations in an intersection for it to be included
#' @param max_size maximal number of observations in an intersection for it to be included
#' @param keep_empty_groups whether empty sets should be kept (including sets which are only empty after filtering by size)
#' @param warn_when_dropping_groups whether a warning should be issued when empty sets are being removed
#' @param sort_sets whether to sort the rows in the intersection matrix (descending sort by default); one of: `'ascending'`, `'descending'`, `FALSE`
#' @param sort_intersections whether to sort the columns in the intersection matrix (descending sort by default); one of: `'ascending'`, `'descending'`, `FALSE`
#' @param sort_intersections_by the mode of sorting, the size of the intersection (cardinality) by default; one of: `'cardinality'`, `'degree'`, `'ratio'`
#' @export
upset_data = function(
    data, intersect, min_size=0, max_size=Inf,
    keep_empty_groups=FALSE, warn_when_dropping_groups=TRUE,
    sort_sets='descending',
    sort_intersections='descending',
    sort_intersections_by='cardinality',
    union_count_column='union_size', intersection_count_column='intersection_size'
) {
    check_sort(sort_sets)
    check_sort(sort_intersections)

    check_sort(sort_intersections_by, allowed=c('cardinality', 'degree', 'ratio'), what='method')

    intersect = unlist(intersect)
    if (length(intersect) == 1) {
        stop('Needs at least two indicator variables')
    }

    # convert to logical if needed
    is_column_logical = sapply(data[, intersect], is.logical)
    if (any(!is_column_logical)) {
        non_logical = names(is_column_logical[is_column_logical == FALSE])
        print(paste('Converting non-logical columns to binary:', paste(non_logical, collapse=', ')))
        data[, non_logical] = sapply(data[, non_logical], as.logical)
    }

    data$intersection = apply(
      data[intersect], 1,
      names_of_true
    )
    data$intersection[data$intersection == ''] = 'NOT_IN_EITHER_GROUP'

    intersections_by_size = table(data$intersection)

    if(min_size > 0 || max_size != Inf) {
        intersections_by_size = intersections_by_size[
            (intersections_by_size >= min_size)
            &
            (intersections_by_size <= max_size)
        ]
        data = data[data$intersection %in% names(intersections_by_size), ]

        # once the unused intersections are removed, we need to decide
        # if the groups not participating in any of the intersections should be kept or removed
        if (!keep_empty_groups) {
            itersect_data = data[, intersect]
            is_non_empty = sapply(itersect_data, any)
            empty_groups = names(itersect_data[!is_non_empty])
            if (length(empty_groups) != 0 && warn_when_dropping_groups) {
                to_display = ifelse(
                    length(empty_groups) <= 5,
                    paste('Dropping empty groups:', paste(empty_groups, collapse=', ')),
                    paste('Dropping', length(empty_groups), 'empty groups')
                )
                print(to_display)
            }
            intersect = intersect[!(intersect %in% empty_groups)]
        }
    }

    stacked = stack(data, intersect)

    stacked$id = rep(1:nrow(data), length(intersect))

    stacked = stacked[stacked$values == TRUE, ]
    stacked$group = stacked$ind

    groups_by_size = table(stacked$group)
    if (sort_sets != FALSE) {
        groups_by_size = groups_by_size[get_sort_order(groups_by_size, sort_sets)]
    } else {
        groups_by_size = groups_by_size[names(groups_by_size)]
    }
    sorted_groups = names(groups_by_size)

    if (sort_intersections != FALSE) {

        if (sort_intersections_by == 'cardinality') {
            sort_value = intersections_by_size
        } else if (sort_intersections_by == 'degree') {
            original_intersections_names = names(intersections_by_size)
            sort_value = count_occurrences(original_intersections_names, '-')
            names(sort_value) = original_intersections_names
        } else if (sort_intersections_by == 'ratio') {
           unsorted_union_sizes = compute_unions(stacked, names(intersections_by_size))
            sort_value = intersections_by_size
            sort_value = sort_value / unsorted_union_sizes
        }

        intersections_by_size = intersections_by_size[
            get_sort_order(sort_value, sort_intersections)
        ]
    }
    sorted_intersections = names(intersections_by_size)

    matrix_data = compute_matrix(sorted_intersections, sorted_groups)

    group = rownames(matrix_data)

    matrix_frame = gather(
        cbind(group, matrix_data),
        'group',
        'intersection',
        'value'
    )

   union_sizes = compute_unions(stacked, sorted_intersections)

   with_sizes = data.frame(data)

   with_sizes[[union_count_column]] = sapply(data$intersection, function(intersection) { union_sizes[intersection] })
   with_sizes[[intersection_count_column]] = sapply(data$intersection, function(intersection) { intersections_by_size[intersection] })

  list(
    with_sizes=with_sizes,
    sets_ordering_in_ids=intersect,
    intersected=data,
    presence=stacked,
    matrix=matrix_data,
    matrix_frame=matrix_frame,
    sorted=list(
      groups=sorted_groups,
      intersections=sorted_intersections
    ),
    union_sizes=union_sizes
  )
}


#' @export
upset_themes = list(
  intersections_matrix=list(
    theme_minimal(),
    theme(
      # hide intersections
      axis.text.x=element_blank(),
      axis.ticks.x=element_blank(),
      # hide group title
      axis.title.y=element_blank()
    ),
    scale_color_manual(
      values=list('TRUE'='black', 'FALSE'='grey85'),
      guide=FALSE
    )
  ),
  'Intersection size'=list(
    theme_minimal(),
    theme(
      axis.text.x=element_blank(),
      axis.title.x=element_blank()
    )
  ),
  overall_sizes=list(
    theme_minimal(),
    theme(
      # hide groups
      axis.title.y=element_blank(),
      axis.text.y=element_blank(),
      axis.ticks.y=element_blank()
    )
  ),
  default=list(
    theme_minimal(),
    theme(
      axis.text.x=element_blank(),
      axis.title.x=element_blank()
    )
  )
)


#' Default themes modified by specified arguments
#'
#' Return the default UpSet themes with all themes modified with provided arguments
#'
#' @param ... arguments passed to `theme()`
#' @export
upset_default_themes = function(...)  {
    sapply(
        upset_themes, function(default) {
            c(default, list(theme(...)))
        }
    )
}


#' Default themes modified by specified component-specific arguments
#'
#' Return the default UpSet themes with specific themes modified with provided themes
#'
#' @param to_update a named list of themes to be used to modify themes of specific components; see `names(upset_themes)` for components names.
#' @export
upset_modify_themes = function(to_update)  {
    c(
        sapply(
            names(to_update),
            function(name) {
                c(upset_themes[[name]], to_update[name])
            },
            simplify=FALSE
        ),
        upset_themes[setdiff(names(upset_themes), names(to_update))]
    )
}


#' Annotation panel shorthand
#'
#' Simplifies creation of annotation panels, automatically building aesthetics mappings,
#' at a cost of lower flexibility than when providing a custom mapping; `aes(x=intersection)` is prespecified.
#'
#' @param y A string with the name of the y aesthetic
#' @param y A geom to be used as an annotation
#' @export
upset_annotate = function(y, geom) {
  list(
    aes=aes_string(x='intersection', y=y),
    geom=geom
  )
}

segment_end = function(matrix_frame, data, intersection, end) {
  corresponding = matrix_frame[matrix_frame$intersection == intersection, ]
  ordering_reference = data$sorted$groups
  reference_order = order(data$sorted$groups)

  h = apply(corresponding, FUN=function(row) {
    group_members = corresponding[
      corresponding$intersection == row['intersection']
      &
        corresponding$value == TRUE
      ,
      'group'
      ]
    g = ordering_reference[sort(reference_order[group_members])]

    ifelse(
      length(g),
      end(g, 1),
      NA
    )
  }, MARGIN=1)
}

upset_stripes = c('grey95', 'white')

matrix_background_stripes = function(data, stripes, orient='horizontal') {
  if (!(orient %in% c('horizontal', 'vertical'))) {
    stop('Incorrect orient')
  }
  if (orient == 'horizontal') {
    aes = aes(x=-Inf, xend=Inf, y=group, yend=group)
  } else {
    aes = aes(y=-Inf, yend=Inf, x=group, xend=group)
  }
  list(
    geom_segment(
      data=data$matrix_frame,
      aes,
      color=ifelse(
        which(data$sorted$groups==data$matrix_frame$group) %% 2 == 0,
        stripes[[1]],
        stripes[[2]]
      ),
      size=7
    )
  )
}


intersection_size_text = list(vjust=-0.25)

#' Barplot annotation of intersections sizes
#' @export
intersection_size = function(
  counts=TRUE,
  bar_number_threshold=0.85,
  text_colors=c(on_background='black', on_bar='white'),
  text=list(),
  text_aes=aes_string(),
  aest=aes_string()
) {
  if (counts) {
    text = modifyList(intersection_size_text, text)
    text_aes = modifyList(
        aes(
            label=..count..,
            y=ifelse(
                ..count.. <= bar_number_threshold * max(..count..),
                ..count..,
                bar_number_threshold * ..count..
            ),
            colour=ifelse(
                ..count.. <= bar_number_threshold * max(..count..),
                'on_background',
                'on_bar'
            )
        ),
        text_aes
    )

    counts_geoms = list(
      do.call(
        geom_text,
        c(
            list(
                stat='count',
                text_aes
            ),
            text
        )
      ),
      scale_color_manual(
        values=text_colors,
        guide=FALSE
      )
    )
  } else {
    counts_geoms = list()
  }

  list(
    aes=modifyList(aes(x=intersection), aest),
    geom=c(
      list(geom_bar()),
      counts_geoms
    )
  )
}


#' Generate percentage label of the interestion/union sizes ratio
#'
#' For use together with `intersection_size` or `intersection_ratio`
#'
#' @param digits How many digits to show when rounding the percentage?
#' @param sep set to space (`' '`) if you prefer a whitespace between the number and the `\%` sign.
#'
#' @export
#' @examples
#' intersection_size(text_aes=aes_(label=upset_text_percentage()))
upset_text_percentage = function(digits=0, sep='') {
    substitute(
        paste(
            round(
                intersection_size / union_size * 100,
                digits
            ),
            '%',
            sep=sep
        )
    )
}


#' Barplot annotation of relative intersections sizes
#'
#' A large intersection size can be driven by a large number of members in a group;
#' to account for that, one can divide the intersection size by the size of a union of the same groups.
#' This cannot be calculated for the null intersection (observations which do not belong to either of the groups).
#' @export
intersection_ratio = function(
  counts=TRUE,
  bar_number_threshold=0.75,
  text_colors=c(on_background='black', on_bar='white'),
  text=list(),
  text_aes=aes_string(),
  aest=aes_string()
) {

  if (counts) {
    text = modifyList(intersection_size_text, text)
    text_aes = modifyList(
        aes(
            label=paste(intersection_size, '/', union_size),
            y=ifelse(
                intersection_size/union_size <= bar_number_threshold * max((intersection_size/union_size)[union_size!=0]),
                intersection_size/union_size,
                bar_number_threshold * intersection_size/union_size
            ),
            colour=ifelse(
                intersection_size/union_size <= bar_number_threshold * max((intersection_size/union_size)[union_size!=0]),
                'on_background',
                'on_bar'
            )
        ),
        text_aes
    )

    counts_geoms = list(
      do.call(
        geom_text,
        c(
            list(
                text_aes,
                check_overlap=TRUE
            ),
            text
        )
      ),
      scale_color_manual(
        values=text_colors,
        guide=FALSE
      )
    )
  } else {
    counts_geoms = list()
  }

  list(
    aes=modifyList(aes(x=intersection), aest),
    geom=c(
      list(geom_col(aes(y=ifelse(union_size == 0, 0, 1/union_size)))),
      counts_geoms
    )
  )
}


#' @export
upset_test = function(
    data,
    intersect,
    comparisons=list()
) {

    comparison = do.call(compare_between_intersections, c(list(data, intersect), comparisons))

    if (nrow(comparison) == 0) {
        stop('No varaibles to compare')
    }

    significant_hits = comparison[comparison$fdr < 0.05, 'variable']

    if (length(significant_hits)) {
        print(paste(
          paste(significant_hits, collapse=', '),
          'differ significantly between intersections'
        ))
    }

    result = comparison[order(comparison$fdr), ]
    result
}


queries_for = function(queries, component) {
    df = list()
    for (query in queries) {
        if (!is.null(query$only_components) && !(component %in% query$only_components)) {
            next
        }
        query$method = ifelse(is.null(query$intersect), 'set', 'intersect')
        query$query = query[[query$method]]
        df[[length(df) + 1]] = query
    }
    as.data.frame(do.call(rbind, df))
}


set_queries = function(queries) {
    queries[queries$method == 'set', ]
}


intersect_queries = function(queries, data) {
    queries = queries[queries$method == 'intersect', ]
    queries$intersect = sapply(
        queries$intersect,
        function(sets) {
            paste(data$sets_ordering_in_ids[data$sets_ordering_in_ids %in% sets], collapse='-')
        }
    )
    queries$query = queries$intersect
    queries
}


without_query_columns = function(queries) {
    queries[
        ,
        !(colnames(queries) %in% c('only_components', 'set', 'intersect', 'method', 'query', 'intersection', 'value', 'group')),
        drop=FALSE
    ]
}


extract_geom_params_for = function(queries, geom) {
    accepted_params = c(geom$geom$aesthetics(), geom$geom$parameters())
    accepted_params[accepted_params == 'colour'] = 'color'
    user_params = as.data.frame(without_query_columns(queries))

    params = user_params[, colnames(user_params) %in% accepted_params, drop=FALSE]
    if (length(unique(params)) == 1)
    {
        params = unique(params)
    }

    params
}


get_highlights_data = function(data, key, queries) {
    if (nrow(queries) > 0) {
        merge(data, queries, by.x=key, by.y='query', all.y=TRUE)
    } else {
        data.frame()
    }
}


highlight_layer = function(geom, data, args=list()) {
    if (nrow(data) == 0) {
        list()
    } else {
        list(
            do.call(
                geom,
                modifyList(
                    c(list(data=data), args),
                    extract_geom_params_for(data, geom())
                )
            )
        )
    }
}


#' Highlight chosen sets or intersections
#'
#' Highlight sets or intersections matching specified query.
#'
#' @param set name of the set to highlight
#' @param intersect a vector of names for the intersection to highlight
#' @param only_components which components to modify; by default all eligible components will be modified; the available components are 'overall_sizes', 'intersections_matrix', 'Intersection size', and any annotations specified
#' @param ... - passed to geoms in modified components
#' @export
#' @examples
#' upset_query(intersect=c('Drama', 'Comedy'), color='red', fill='red')
#' upset_query(set='Drama', fill='blue')
upset_query = function(set=NULL, intersect=NULL, only_components=NULL, ...) {
    if (!is.null(set) && !is.null(intersect)) {
        stop('pass set or intersect, not both')
    }
    list(set=set, intersect=intersect, only_components=only_components, ...)
}


#' Prepare layers for sets sizes plot
#'
#' @param geom the geom to use
#' @param layers a list of additonal layers (scales, geoms) to be included on the plot
#' @param ... passed to the geom
#' @export
upset_set_size = function(geom=geom_bar, layers=list(), ...) {
    args = eval(list(...))
    c(
        list(
            geom(...),
            scale_y_reverse(),
            ylab('Set size'),
            substitute(highlight_layer(geom, overall_sizes_highlights_data, args=args))
        ),
        layers
    )
}


eval_if_needed = function(layers, ...) {
    lapply(
        layers,
        function(layer) {
            if (inherits(layer, 'call')) {
                layer_evaluated = eval.parent(layer, n=3)
                layer_evaluated
            } else {
                layer
            }
        }
    )
}


#' Compose an UpSet plot
#'
#' @param data a dataframe including binary columns representing membership in classes
#' @param intersect which columns should be used to compose the intersection
#' @param queries a list of queries generated with `upset_query()`
#' @param labeller function modifying the names of the sets (rows in the matrix)
#' @param height_ratio ratio of the intersection matrix to intersection size height
#' @param width_ratio ratio of the overall set size width to intersection matrix width
#' @param stripes a two-element characters vector, specifying the background colors for odd and even rows
#' @param dot_size size of the points on the intersection matrix
#' @param set_sizes a list of layers defining the overall set sizes, e.g. from `upset_set_size()` (`FALSE` to hide)
#' @inheritDotParams upset_data
#' @export
upset = function(
  data,
  intersect,
  base_annotations=list(
    'Intersection size'=intersection_size(counts=TRUE)
  ),
  name='group',
  annotations=list(),
  themes=upset_themes,
  stripes=upset_stripes,
  labeller=identity,
  height_ratio=0.5,
  width_ratio=0.3,
  wrap=FALSE,
  set_sizes=upset_set_size(width=0.6),
  queries=list(),
  dot_size=3,
  ...
) {
  annotations = c(annotations, base_annotations)

  data = upset_data(data, intersect, ...)

  show_overall_sizes = !(inherits(set_sizes, 'logical') && set_sizes == FALSE)

  matrix_intersect_queries = intersect_queries(queries_for(queries, 'intersections_matrix'), data)

  query_matrix = get_highlights_data(data$matrix_frame, 'intersection', matrix_intersect_queries)
  query_matrix = query_matrix[query_matrix$value == TRUE, ]

  intersections_matrix = (
    ggplot(data$matrix_frame, aes(x=intersection, y=group))
    + matrix_background_stripes(data, stripes)
    # the dots outline
    + geom_point(color=ifelse(data$matrix_frame$value, 'black', 'grey70'), size=dot_size * 7/6)
    # the dot
    + geom_point(aes(color=value), size=dot_size)
    # the highlighted dot
    + highlight_layer(
        geom_point,
        query_matrix,
        args=list(size=dot_size)
    )
    # interconnectors on the dots
    + geom_segment(aes(
          x=intersection,
          xend=intersection,
          y=segment_end(data$matrix_frame, data, intersection, head),
          yend=segment_end(data$matrix_frame, data, intersection, tail)
    ), na.rm=T)
    # highlighted interconnectors
    + highlight_layer(
        geom_segment,
        query_matrix,
        args=list(
            aes(
                x=intersection,
                xend=intersection,
                y=segment_end(query_matrix, data, intersection, head),
                yend=segment_end(query_matrix, data, intersection, tail)
             ),
             na.rm=T
        )
    )
    + xlab(name)
    + scale_y_discrete(limits=data$sorted$groups, labels=labeller)
    + scale_x_discrete(limits=rev(data$sorted$intersections))
    + themes$intersections_matrix
  )

  rows = list()

  for (name in names(annotations)) {
    annotation = annotations[[name]]
    geoms = annotation$geom

    if (!inherits(geoms, 'list')) {
        geoms = list(geoms)
    }

    annotation_queries = intersect_queries(queries_for(queries, name), data)

    if (nrow(annotation_queries) != 0) {
        highlight_data = merge(data$with_sizes, annotation_queries, by.x='intersection', by.y='intersect', all.y=TRUE)

        geoms_plus_highlights = list()

        for (geom in geoms) {
            geoms_plus_highlights[[length(geoms_plus_highlights) + 1]] = geom
            if (is.null(geom$geom)) { # TODO and on accepted geoms list if any
                next
            }
            highlight_geom = geom

            highlight_geom$geom_params = modifyList(
                geom$geom_params,
                extract_geom_params_for(annotation_queries, geom)
            )

            geoms_plus_highlights[[length(geoms_plus_highlights) + 1]] = layer(

                geom=highlight_geom$geom, params=c(highlight_geom$geom_params, highlight_geom$stat_params),
                stat=highlight_geom$stat,
                data=highlight_data,
                mapping=highlight_geom$mapping,
                position=highlight_geom$position
            )
        }
    } else {
        geoms_plus_highlights = geoms
    }

    if (name %in% names(themes)) {
      theme = themes[[name]]
    } else {
      theme = themes[['default']]
    }

    if (show_overall_sizes) {
        rows[[length(rows) + 1]] = plot_spacer()
    }

    rows[[length(rows) + 1]] = (
      ggplot(data$with_sizes, annotation$aes)
      + geoms_plus_highlights
      + scale_x_discrete(limits=rev(data$sorted$intersections))
      + xlab(name)
      + ylab(name)
      + theme
    )
  }

  if (show_overall_sizes) {
      overall_sizes_queries = set_queries(queries_for(queries, 'overall_sizes'))
      overall_sizes_highlights_data = get_highlights_data(data$presence, 'group', overall_sizes_queries)

      overall_sizes = (
        ggplot(data$presence, aes(x=group))
        + matrix_background_stripes(data, stripes, 'vertical')
        + coord_flip()
        + eval_if_needed(set_sizes, overall_sizes_highlights_data=overall_sizes_highlights_data)
        + scale_x_discrete(limits=data$sorted$groups)
        + themes$overall_sizes
      )

      matrix_row = list(overall_sizes, intersections_matrix)
  } else {
      matrix_row = list(intersections_matrix)
  }

  if (length(rows)) {
    annotations_plots = Reduce(f='+', rows)
    matrix_row = c(list(annotations_plots), matrix_row)
  } else {
    annotations_plots = list()
  }

  plot = Reduce(f='+', matrix_row)

  if (show_overall_sizes) {
      width_ratios = c(width_ratio, 1 - width_ratio)
  } else {
      width_ratios = 1
  }

  plot = plot + plot_layout(
    widths=width_ratios,
    ncol=1 + ifelse(show_overall_sizes, 1, 0),
    nrow=length(annotations) + 1,
    heights=c(
      rep(1, length(annotations)),
      height_ratio
    )
  )

  if (wrap) {
    wrap_elements(plot)
  } else {
    plot
  }
}
