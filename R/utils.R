##---------------------------------------------------------
###   RESULT-GENERATING AND OTHER HELPER/INTERNAL FUNCTIONS
###--------------------------------------------------------


### %notin% operator ###
# ---------------------------------------------------------------------------------------------------------------------------------------------------------
`%notin%` <- Negate( `%in%` )
# ---------------------------------------------------------------------------------------------------------------------------------------------------------



####################################################################################################
#################################### Quantile Cutting Function #####################################
####################################################################################################
# ---------------------------------------------------------------------------------------------------------------------------------------------------------
quant_cut<-function(var,x,df){
  
  xvec<-vector() # initialize null vector to store
  
  for (i in 1:x){
    xvec[i]<-i/x
  }
  
  qs<-c(min(df[[var]],na.rm=T), quantile(df[[var]],xvec,na.rm=T))
  
  df[['new']]=x+1 # initialize variable
  
  for (i in 1:(x)){
    df[['new']]<-ifelse(df[[var]]<qs[i+1] & df[[var]]>=qs[i],
                        c(1:length(qs))[i],
                        ifelse(df[[var]]==qs[qs==max(qs)],x,df[['new']]))
  }
  
  return(df[['new']])
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------------



####################################################################################################
#################################### Trend Variable Function #######################################
####################################################################################################
# ---------------------------------------------------------------------------------------------------------------------------------------------------------

trend_func<-function(rank.var,cont.var,df,trend.var,x){
  
  df[[trend.var]] = 1
  
  medians<-vector()
  
  for (i in 1:x){
    
    newdf<-df[df[[rank.var]]==i,]
    
    medians[i]<-median(newdf[[cont.var]],na.rm=T)
    
    df[[trend.var]]<-ifelse(df[[rank.var]]==i,medians[i],df[[trend.var]])
    
  }
  
  return(df)
}
# ---------------------------------------------------------------------------------------------------------------------------------------------------------



####################################################################################################
################################### Spline Plotting Function #######################################
####################################################################################################
# ---------------------------------------------------------------------------------------------------------------------------------------------------------

hr_splines <- function( dat, x, time, mort.ind, knots, 
                        covariates, wts = NULL, referent = "median", xlab, ylab, 
                        legend.pos, y.max = 1.5 ){
  require( rms )
  require( tidyverse )
  require( GenKern )
  # dat = a data.frame or tibble
  # x = a character string with the name of the x variable
  # time = survival time variable as a string
  # mort.ind = censor/event variable name as a string
  # knots = an integer--the number of interior knots
  # covariates = a vector of character strings with the covariate column names
  # wts = name of weight variable
  # referent = either "median", "mean", "min", or "max". establishes what the referent hazard is
  # xlab = x-label for plot that is returned
  # ylab = y-label for plot that is returned
  # legend.pos = position of legend on plot (ggplot style coordinates)
  # ymax = a number/parameter to control the max y-value on the y-scale
  
  
  # ensure variable is numeric
  dat$x <- as.numeric( eval( parse( text = paste0( "dat$", x ) ) ) )
  df2 <- dat %>% filter( !is.na( x ) & inc == 1 ) # need to remove all NA"s to get `nearest` to function properly
  
  # `rms` summary of distributions (these data characteristics are stored before fitting model)
  dd <<- rms::datadist( dat ) # use the superassignment operator to put dd into global environment, otherwise function breaks
  
  # set the referent value
  dd$limits$x[2] <- unique( df2[GenKern::nearest( df2$x, eval( parse( text = paste0( referent, "( ", "df2$x, na.rm = T )" ) ) ) ), "x"] )
  options( datadist = "dd" )
  
  
  ## Model fitting ##
  
  # formula
  f1 <- paste0( "Surv( ", time, ", ", mort.ind, " ) ~ rcs( x, ", knots, 
                " )", {if( !is.null( covariates ) ) "+"}, paste0( covariates, collapse = " + " ), "+ cluster( sdmvpsu )" )
  
  # normalize the weights
  if ( !is.null( wts ) ) df2 <- df2 %>% mutate( n.wts = get( wts ) / mean( get( wts ), na.rm = T ) )
  
  # fit the model
  if ( !is.null( wts ) )  modelspline <- cph( formula( f1 ), data = df2, weights = n.wts )
  if ( is.null( wts ) )  modelspline <- cph( formula( f1 ), data = df2 )
  
  # predict from model
  pdata1 <- rms::Predict( modelspline, 
                          x, 
                          ref.zero = TRUE, 
                          fun = exp )
  
  # store predictions in a new data.frame and prepare that frame for plotting
  newdf <- data.frame( pdata1 )
  newdf$relative <- 1
  newdf$all <-"Referent ( HR = 1 )"
  newdf$ci <-"95% Confidence Bounds"
  
  # generate the plot
  sp.plot <- ggplot2::ggplot( data = newdf, mapping = aes( x = x, y = yhat ) )+
    geom_line( linewidth = 0.8 ) +
    geom_ribbon( aes( ymin = lower, ymax = upper, col = ci, fill = ci ), alpha = 0.2 )+
    theme_classic( )+
    geom_line( aes( y = relative, x = x, linetype = all ) )+
    scale_linetype_manual( values = c( "dashed" ) )+
    theme( legend.position = legend.pos, 
           text = element_text( family ="Avenir" ), 
           legend.title = element_blank( ), 
           legend.spacing.y = unit( 0.01, "cm" ), 
           legend.text = element_text( size = 8 ) )+
    coord_cartesian( ylim = c( 0, max = ( max( newdf$yhat )*y.max ) ) ) +
    labs( x = xlab, y = ylab )
  
  return( sp.plot )
}
# ---------------------------------------------------------------------------------------------------------------------------------------------------------



####################################################################################################
################################ Results Function (For Survival Analysis) ##########################
####################################################################################################
# ---------------------------------------------------------------------------------------------------------------------------------------------------------

res <- function( df, x, subs, cuts, id.col, covars, time, mort.ind, sample.name, scale.y,
                 int.knots, model.name ){
  
  require( tidyverse )
  require( glue )
  require( splines )
  
  these <- which( eval( parse( text = ( paste0( "df$", subs, collapse = " & " ) ) ) ) )
  
  # compute quantile rank  and trend variable on subsample of interest and recombine
  d.1 <- df[ these, ] %>%
    mutate( !!paste0( x, ".q" ) := as.factor( quant_cut( var = x, x = cuts, df = . ) ) ) %>%
    bind_rows( df[ -these, ], . ) %>%
    trend_func( rank.var = paste0( x, ".q" ), cont.var = x, df = ., trend.var = paste0( x, ".trend" ), x = 5 )
  
  des <- svydesign(id = ~sdmvpsu, weights = ~wtdr18yr, strata = ~sdmvstra, 
                   nest = TRUE, survey.lonely.psu = "adjust", data = d.1)
  
  des <- subset( des, eval( parse( text = paste0( subs, collapse = " & " ) ) ) ) #inclusions
  
  
  
  ## Important function arguments ##
  
  # standard deviation to scale continuous predictor
  x.scale <- sd( df[ these, x ] )
  
  # knots at the medians of quantiles
  kts <- paste0( levels( as.factor( d.1[[ paste0( x, ".trend" )]] ) ), collapse = ", " )
  
  # levels of cat variable
  cat.l <- levels( as.factor( d.1[[ paste0( x, ".q" ) ]] ) )
  
  ## Fit Models ##
  
  # quantile specification
  m.q <- svycoxph( formula( paste0( "Surv(", time, ",",mort.ind," ) ~ ", paste0( x, ".q" ), {if( !is.null( covars ) ) "+"}, paste0( covars, collapse = " + ") ) ),
                   design = des )
  
  sum.m.q <- summary( m.q )$coefficients %>% data.frame()
  ci.m.q <- confint( m.q )
  
  # trend test
  m.t <- svycoxph( formula( paste0( "Surv(", time, ",",mort.ind," ) ~ ", paste0( x, ".trend" ), {if( !is.null( covars ) ) "+"}, paste0( covars, collapse = " + ") ) ),
                   design = des )
  
  sum.m.t <- summary( m.t )$coefficients %>% data.frame()
  
  # linear specification
  m.l <- svycoxph( formula( paste0( "Surv(", time, ",",mort.ind," ) ~ ", paste0( "I( ", x, "/", x.scale, ")", {if( !is.null( covars ) ) "+"} ), paste0( covars, collapse = " + ") ) ),
                   design = des )
  
  sum.m.l <- summary( m.l )$coefficients %>% data.frame()
  ci.m.l <- confint( m.l )
  
  # length of observations used
  n.table <- length( m.l$linear.predictors )

  
  # natural cubic spline 
  # degrees of freedom are the no. of interior knots + 2 (also the no. of basis functions required)--(see "Elements of Statistical Learning" by Hastie, Tibshirani and Friedman and https://stats.stackexchange.com/questions/490306/natural-splines-degrees-of-freedom and https://stats.stackexchange.com/questions/7316/setting-knots-in-natural-cubic-splines-in-r) (also note that when we specify df = 4 we assume three interior knots and 2 boundary knots--this syntax does not include the basis function for the intercept in the count)
  m.cs <- svycoxph( formula( paste0( "Surv(", time, ",", mort.ind," ) ~ ", paste0( "ns(", x,", df =", ( int.knots + 1 )," )", {if( !is.null( covars ) ) "+"} ), 
                                     paste0( covars, collapse = " + ") ) ),
                    design = des )
  
  
  # Non-linearity Likelihood-Ratio test
  p.nl <- pchisq( abs( m.l$ll[2] -  m.cs$ll[2] ),
                  df = m.l$degf.resid - m.cs$degf.resid, lower.tail = FALSE )

  
  ## Generate Table ##
  
  
  # first table for odds ratios across quantiles
  res.mat.q <- matrix( ncol = 2 )
  res.mat.q[, 1 ] <- x
  res.mat.q[, 2 ] <- "1.00" # referent
  
  for( i in 2:cuts ){
    
    # model object row of interest
    cut.obj <- sum.m.q[ which( str_detect( rownames( sum.m.q ) , paste0( x,".q", cat.l[i]) ) ), ]
    
    # confidence interval object row of interest
    cut.ci <- exp( ci.m.q[ which( str_detect( rownames( sum.m.q ) , paste0( x,".q", cat.l[i]) ) ), ] )
    
    # put together row in table
    res.mat.q <- cbind( res.mat.q, paste0( round( exp( cut.obj[, "coef" ] ), 2 ),
                                           " (",
                                           paste0( round( cut.ci[1], 2 ), "-", round( cut.ci[2], 2 ) ),
                                           ")" ) )
    # asterisk on significant results
    if( cut.obj[, 6] < 0.05 & cut.obj[, 6] >= 0.01 ){
      res.mat.q[, (i+1)] <- paste0( res.mat.q[, (i+1)], "*" )
    }
    
    if( cut.obj[, 6] < 0.01 ){
      res.mat.q[, (i+1)] <- paste0( res.mat.q[, (i+1)], "**" )
    }
    
  }
  
  # add trend test p-value
  t.obj <- sum.m.t[ which( str_detect( rownames( sum.m.t ) , paste0( x,".trend" ) ) ), ]
  
  res.mat <- cbind( res.mat.q, round( t.obj[, 6], 2 ) )
  
  # asteriks
  if( t.obj[, 6] < 0.05 & t.obj[, 6] >= 0.01 ){
    res.mat[, ncol( res.mat ) ] <- paste0( res.mat[, ncol( res.mat ) ], "*" )
  }
  
  if( t.obj[, 6] < 0.01 ){
    res.mat[, ncol( res.mat ) ] <-  paste0( "< 0.01**" )
  }
  
  # add linear specification OR and 95% CI
  l.obj <- sum.m.l[ which( str_detect( rownames( sum.m.l ) , paste0( x ) ) ), ]
  l.ci <- exp( ci.m.l[ which( str_detect( rownames( sum.m.l ) , paste0( x ) ) ), ])
  
  res.mat <- cbind( res.mat, paste0( round( exp( l.obj[, "coef" ] ), 2 ),
                                     " (",
                                     paste0( round( l.ci[1], 2 ), "-", round( l.ci[2], 2 ) ),
                                     ")" ) )
  
  # asteriks
  if( l.obj[, 6] < 0.05 & l.obj[, 6] >= 0.01 ){
    res.mat[, ncol( res.mat ) ] <- paste0( res.mat[, ncol( res.mat ) ], "*" )
  }
  
  if( l.obj[, 6] < 0.01 ){
    res.mat[, ncol( res.mat ) ] <- paste0( res.mat[,ncol( res.mat ) ], "**" )
  }
  
  # add lrt p-value
  
  res.mat <- cbind( res.mat, round( p.nl, 2 ) )
  
  # asteriks
  if( p.nl < 0.05 & p.nl >= 0.01 ){
    res.mat[, ncol( res.mat ) ] <- paste0( res.mat[, ncol( res.mat ) ], "*" )
  }
  
  if( p.nl < 0.01 ){
    res.mat[, ncol( res.mat ) ] <-  paste0( "< 0.01**" )
  }
  
  # column names 
  res.frame <- data.frame( res.mat )
  colnames(res.frame) <- c( "index", paste0( "Q", 1:cuts ), "p.trend", "linear", "p.nonlinear" )
  
  
  # add n to table
  res.frame$n <- n.table
  res.frame <- res.frame %>%
    relocate( n, .before = Q1 )
  
  # add subsample and model names to table
  res.frame$sample <- sample.name
  res.frame$model <- model.name
  res.frame <- res.frame %>%
    relocate( sample, .before = n ) %>%
    relocate( model, .after = sample )
    
  
  ## Significant digits ##
  
  # column indices for odds ratio/ci
  col.ind.q <- c( which( str_detect( colnames( res.frame ), "Q\\d" ) ), 
                  which( str_detect( colnames( res.frame ), "^linear$" ) ) )
  
  # odds ratios and confidence intervals
  for( i in col.ind.q ) {
    res.frame[,i] <- str_replace( res.frame[,i], '(\\(\\d)\\,', "\\1\\.00," ) # match open parenthesis followed by a digit and then a comma. Retain everything except the comma and add ".00,"
    res.frame[,i] <- str_replace( res.frame[,i], "(\\(\\d\\.\\d)\\,","\\10\\,") # match open parenthesis followed by a digit, period, digit, and then a comma. Retain everything except the comma and add ".0,"
    res.frame[,i] <- str_replace( res.frame[,i], "(\\(\\d\\.\\d)\\,", "\\10\\," ) # match open parenthesis followed by digit, period, digit and comma.Retain everything except the comma and add "0,"
    res.frame[,i] <- str_replace( res.frame[,i], "(\\d\\.\\d)\\s", "\\10 " ) # match digit, period, digit and space. Retain everything except space and add "0 "
    res.frame[,i] <- str_replace( res.frame[,i], "^(\\d)\\s\\(", "\\1\\.00 \\(" ) # match beginning of string followed by single digit, followed by a space and parenthesis. Reatin the single digit and and ".00 ()
    res.frame[,i] <- str_replace( res.frame[,i], "(\\d\\.\\d)\\)", "\\10\\)") # match digit, period, digit, close parenthesis. Retain everything except parenthesis and add "0)" to end
    res.frame[,i] <- str_replace( res.frame[,i], "(\\,\\s\\d)\\)", "\\1.00\\)") # match comma, space, digit, close parenthesis. Retain everything except parenthesis and add ".00)" to end
    res.frame[,i] <- str_replace( res.frame[,i], "(\\(\\d\\.\\d)\\-", "\\10\\-") # open parenthesis, digit, period, digit, hypen. Retain everything except hyphen and add "0)" to end
    res.frame[,i] <- str_replace( res.frame[,i], "(\\-\\d)\\)", "\\1.00\\)") # match hyphen, digit, close parenthesis. Retain everything except parenthesis and add ".00)" to end
    res.frame[,i] <- str_replace( res.frame[,i], "(\\(\\d)\\-", "\\1.00\\-") # match hyphen, digit, close parenthesis. Retain everything except parenthesis and add ".00)" to end
  }
  
  # column indices for columns containing p values 
  col.ind.p <- which( str_detect( colnames( res.frame ), "p\\." ) )
  
  for( i in col.ind.p ){
    res.frame[,i] <- str_replace( res.frame[,i], "(\\d\\.\\d)$", "\\10" ) # match digit, period, digit,end and add a 0 before the end
    res.frame[,i] <- str_replace( res.frame[,i], "^1$", "0.99" ) # round down probabilities = 1
  }
  
  
  ## Spline plot ##
  
  
  spline.plot <- hr_splines(  dat =  des$variables
                              %>% select(  -permth_exm ), 
               x =  x, 
               time =  time, 
               mort.ind =  mort.ind, 
               knots = ( int.knots + 2 ), # see: https://stackoverflow.com/questions/54957104/restricted-cubic-spline-output-in-r-rms-package-after-cph and https://stats.stackexchange.com/questions/558759/difference-between-splines-from-different-packages-mgcv-rms-etc for how `rcs` counts df (in this usage, `knots` option includes all knots--boundary plus interior knots which include the intercept-- so we have two interior knots + 2 boundary knots which gives us knots = 4)
               covariates =  covars, 
               wts =  "wtdr18yr", 
               referent =  "median", 
               ylab =  "Hazard Ratio", 
               y.max = scale.y,
               xlab =  NULL, legend.pos =  c(  0.4 , 0.8 ) )
  
  
  return( list( frame = res.frame, q.obj = m.q,
                dat = des$variables,
                spline.plot = spline.plot ) )
}

# res( df = d, x = "fs_enet", subs = "inc == 1", cuts = 5, id.col = "seqn", covars = covars.logit, time = "stime", mort.ind = "mortstat")

# ---------------------------------------------------------------------------------------------------------------------------------------------------------



####################################################################################################
################################# Table 1 (Categorical Variables) ##################################
####################################################################################################
# ---------------------------------------------------------------------------------------------------------------------------------------------------------

epitab <- function(var,data.fr,des,table.var){
  
  attach(data.fr)
  
  typ<-paste0('~',var)
  sumcat=0
  for (i in 1:length(levels(factor(data.fr[[var]])))){
    sumcat<-sumcat+((svytable(formula(typ),design=des)[i]))
  }
  
  wtpct<-vector()
  
  for (i in 1:length(levels(factor(data.fr[[var]])))){
    wtpct[i]<-round((svytable(formula(typ),design=des)[i]/sumcat*100),digits=1)
  }
  wtpct
  wtpct<-c(' ',wtpct,' ')
  total<-vector()
  
  for (i in 1:length(levels(factor(data.fr[[var]])))){
    total[i]<-table(des[["variables"]][var])[i]
  }
  total<-c(' ',total,' ')
  
  levelnames<-c(table.var,levels(as.factor(data.fr[[var]])),' ')
  levelnames<-levelnames[!is.na(levelnames)==T]
  levelnames<-levelnames[!levelnames=='Missing/unknown']
  merged<-data.frame(cbind(levelnames,paste0(total,' (',wtpct,')')))
  
  colnames(merged)<-c('levelnames','mn')
  merged
  detach(data.fr)
  return(merged)
  
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------------



####################################################################################################
################################## Table 1 (Continuous Variables) ##################################
####################################################################################################
# ---------------------------------------------------------------------------------------------------------------------------------------------------------

epitab.means <- function(cont.var, des, table.var, dig){ 
  # dig is the number of digits to round to
  mn<-paste0(round(svymean(as.formula(paste0('~',cont.var)),design = des,na.rm=T)[1],digits=dig),
             ' (',round(sqrt(svyvar(as.formula(paste0('~',cont.var)),design = des,na.rm=T))[1],digits=dig),')')
  
  ms2<-data.frame(c('',table.var,''),c('',mn,''))
  
  colnames(ms2)<-c('levelnames','mn')
  
  return(ms2)
}

# ---------------------------------------------------------------------------------------------------------------------------------------------------------



####################################################################################################
################################## Survey-Weighted Cohen's D ######################################
####################################################################################################
# ---------------------------------------------------------------------------------------------------------------------------------------------------------

svycd <- function( x, design.1, design.2, ... ){
  
  # x: a character with the variable name ( must be length of 1)
  # design.1: the design object for the first group
  # the design object for the second group 
  # note that the computation will be done as the subtraction of the group in `design.1`. Therefore, make sure to include the group you want first as the `design.1` object.
  
  if ( length( x ) > 1 ) stop( "Length of x must be no greater than 1.")
  
  design.list <- list( design.1, design.2 )
  
  #initialize lists to store values
  mns <- vector()
  sds <- vector()
  
  # formula for function calls below inside loop
  f <- formula( paste0( "~", x ) )
  
  # loop
  for( i in seq_along( design.list ) ){
    
    mns[[i]] <- svymean( x = f, design = design.list[[i]], na.rm = T )
    sds[[i]] <- svysd( formula = f, design = design.list[[i]], na.rm = T )
    
  }
  
  # cohen's d
  cohen.d <- setNames( ( mns[1] - mns[2] ) / sqrt( ( sds[1] + sds[2] ) / 2 ),
                       "cohens.d" )
  
  # return
  return( cohen.d )
}

# example
# svycd( x = "fs_enet", design.1 = fiw, design.2 = fsw)

# ---------------------------------------------------------------------------------------------------------------------------------------------------------



####################################################################################################
######################### Residual Method for Total Calorie Adjustment #############################
####################################################################################################
# ---------------------------------------------------------------------------------------------------------------------------------------------------------

# Helper function #

svy_residual_bind <- function( x, design, cal ) {
  # x = a character string; the column name of the nutrient of interest
  # cal = a character string; the column name for the calories column
  # design = a `svydesign` object
  # dependencies: `survey`
  
  # working dataset
  dat <- design$variables
  
  # regress nutrients on calories
  mod <- svyglm( formula = formula( paste0( x," ~ ", cal ) ), 
                 family=stats::gaussian(),
                 design = design )
  
  # extract residuals
  step.1.residuals <- mod$residuals
  
  
  ## add arbitrary constant value since residuals have mean 0 ##
  
  # will add the predicted value for the mean value of calories in the dataset
  step.2.residuals <- data.frame( step.1.residuals + ( mod$coefficients[1] + mod$coefficients[2]*mean( dat[[ cal ]], na.rm = T ) ) )
  colnames( step.2.residuals ) <- "x.adjusted"
  
  # create rowid column based on rownames of the model matrix (will be used for faithful merging)
  step.2.residuals <- step.2.residuals %>%
    mutate( rowid = rownames( mod$model ) )  # label residuals by their rowid
  
  # join residuals to original dataframe using rowid (this ensure missings are set to missing accordingly)
  dat <- dat %>%
    mutate( rowid = rownames( dat ) ) %>%
    left_join( step.2.residuals, by = "rowid" )
  
  return( dat %>% select( rowid, x.adjusted ) )
}


# Main function #

svy_energy_residual <- function( design, nutr, calories, overwrite = "no" ){
  
  # design = a `svydesign` object
  # nutr = the nutrient/food group/ index score needing to be energy adjusted ( can be a single variable or 
  # a vector of character strings with each item representing a different column)
  # calories = a character vector (single column) indicating the column name for total calories
  # df is a dataframe:
  # overwrite = a "yes" or "no", depending on if use wants to overwrite previous versions of the columns and keep the
  # same column names. Default is "no". if "no" is selected, the program generates two new columns with ".adj" appended to the old column names
  # RETURN: this function returns a dataframe with the energy adjusted variables appended to the end of the
  # frame and named by pasting their original name with ".adj" at the end of the string or the original column names.
  
  ## checks ##
  
  if( overwrite %notin% c( "yes", "no" ) ) stop( '`overwrite` must be one of "yes" or "no"')
  
  ## working data ##
  
  dat <- design$variables
  
  ## regress diet index scores on total energy and extract residuals ##
  
  
  # loop and bind residuals for all "x" variables
  dat.list <- list()
  for( i in 1: length( nutr ) ) {
    
    h <- svy_residual_bind( x = nutr[i], design = design, cal = calories ) 
    
    if( overwrite == "no" ){
      
      dat.list[[i]] <- h %>%
        rename( !!paste0( nutr[i], ".adj" ) := x.adjusted ) # rename column according to input variable names
    }
    
    else if( overwrite == "yes" ){
      
      dat.list[[i]] <- h %>%
        rename( !!paste0( nutr[i] ) := x.adjusted )
    }
    
  }
  
  ## bind columns and produce final data output ##
  
  if( overwrite == "no" ){
    dat <- dat %>% mutate( rowid = rownames( dat ) )  # create a rowid column for merge
  }
  
  else if( overwrite == "yes" ){
    dat <- dat %>% mutate( rowid = rownames( dat ) ) %>%  # create a rowid column for merge
      select (- nutr ) # remove old old columns of the x variables if they are to be overwritten
  }
  
  out.dat <- dat.list %>% reduce( inner_join, by = "rowid" ) %>%  # inner_join all elements of the list
    data.frame() %>%
    left_join( dat, ., by = "rowid" ) %>%
    select( -rowid )
  
  return( out.dat )
  
}

# Example:
# d.8 <- svy_energy_residual( nutr = "nar.b6", 
#                      design = des.1, 
#                      calories = "kcal",
#                      overwrite = "no" )

# ---------------------------------------------------------------------------------------------------------------------------------------------------------


####################################################################################################
################################## Dietary Patterns: Penalized Logit ######################################
####################################################################################################

# ---------------------------------------------------------------------------------------------------------------------------------------------------------
enet_pat <- function( xmat, yvec, wts, plot.title, seed = 28 ){
  
  # performs penalized logistic regression with the elastic net penalty
  
  # xmat = the x matrix with columns being the features and rows the observations
  # yvec = the y vector. must be of the same length as the number of rows of `xmat`
  # wts = the weights vector. must be the same length as `yvec`
  # seed = seed set for reproducibility. a default value is provided
  
  colorss <- c( "black", "red", "green3", "navyblue",   "cyan",   "magenta", "gold", "gray",
                'pink', 'brown', 'goldenrod' ) # colors for plot
  
  # initialize lists to store outputs
  store <- list( )
  coefsdt <- list( )
  
  alpha.grid <- seq( 0, 1, 0.1 ) # range of alpha values for tuning grid
  
  for ( i in 1:length( alpha.grid ) ){ # set the grid of alpha values
    
    set.seed( seed ) # seed to reproduce results
    
    # call glmnet with 10-fold cv
    enetr <- cv.glmnet( x = xmat, y = yvec, family = 'binomial', weights = wts,
                        nfold = 10, alpha = alpha.grid[ i ] )
    
    # bind values of lambda to cross validation error
    evm <- data.frame( cbind( enetr$lambda, enetr$cvm ) )
    colnames( evm ) <- c( 'lambda', 'av.error' )
    
    # now create a list that stores each coefficients matrix for each value of alpha
    # at the lambda minimizer
    coefsdt[[ i ]] <- list( alpha = paste0( alpha.grid )[ i ], 
                            coefs = coef( enetr, s = "lambda.min" ) )
    
    # create a dataframe that houses the alpha, min lambda, and average error
    resdf <- data.frame( alpha = alpha.grid[ i ], 
                         evm[ which( evm$av.error == min( evm$av.error ) ), 'lambda' ],
                         av.error = evm[ which( evm$av.error == min( evm$av.error ) ), 'av.error' ] )
    colnames( resdf ) <- c( 'alpha', 'lambda', 'av.error' )
    
    store[[ i ]] <- resdf
    
    ## generate plot ##
    
    if ( i == 1 ){ # for the first value of 'i'
      plot( x = enetr$lambda, y = enetr$cvm, type ='l', 
            ylim = c( min( enetr$cvm ) - 0.02, max( enetr$cvm ) - 0.02 ),
            xlim = c( min( evm$lambda ), ( resdf$lambda*1.05 ) ), 
            las = 0, 
            cex.axis = 0.7 )
    }
    else if ( i != 1 ){ # each additional line will be superimposed on the plot with a different color
      lines( x = enetr$lambda, 
             y = enetr$cvm, 
             col = colorss[ i ] )
    }
  }
  
  ## superimpose intersecting lines at the minimizer ## 
  cverr <- do.call( 'rbind', store ) # this gives the table of errors for each combination of alpha and lambda
  abline( h = cverr[ which( cverr$av.error == min( cverr$av.error ) ), 'av.error' ],
          lty = 2 )
  abline( v = cverr[ which( cverr$av.error == min( cverr$av.error ) ), 'lambda' ],
          lty = 2 )
  
  
  ## add optimal lambda and alpha values to plot title ## 
  optimall <- cverr[ which( cverr$av.error == min( cverr$av.error ) ), ] # here I extract the optimal combination of
  
  # lambda and alpha
  optlam <- signif( optimall[ 2 ], 2 )
  opta <- optimall[ 1 ]
  title( main = TeX( paste0( plot.title, ' ( $\\lambda_{optimal} =$', optlam, ' and $\\alpha_{optimal} =$', opta, ' )' ) ),
         cex.main = 0.8,
         cex.lab = 0.8,
         xlab = TeX( '$\\lambda$' ), 
         mgp = c( 2, 1, 0 ),
         ylab ='Deviance', mgp = c( 2, 1, 0 ) )
  
  
  
  # the function returns the optimal lambda alpha combo and the set of coefficients that 
  # correspond to that combination of parameters
  return( list( optimall, coefs = as.matrix( coefsdt[[ which( alpha.grid == optimall$alpha ) ]]$coefs )[ -1, ] ) )
}
# ---------------------------------------------------------------------------------------------------------------------------------------------------------

