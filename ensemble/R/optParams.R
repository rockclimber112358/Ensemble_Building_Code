optParams <-
function(func, form=NULL, data=NULL, x=NULL, y=NULL
  ,nTrain=c(100,1000,10000), nValid=nTrain, replications=rep(30, length(nTrain))
  ,optFunc=function(pred,actual){mean((pred-actual)^2)}
  ,optArgs=list()
  ,optVals=rep(5,length(optArgs))
  ,optRed=rep(.7,length(optArgs))
  ,predFunc=predict
  ,constArgs=list()
  ,coldStart=10
  ,seed=321)
{
  set.seed(seed)
  #data quality checks
  if(!is(func,"function"))
    stop("func must be a function!")
  if(is.null(form) & (!is.null(data) | is.null(x) | is.null(y)))
    stop("Must specify form, data OR x, y")
  if(is.null(x) & (!is.null(y) | is.null(form) | is.null(data)))
    stop("Must specify form, data OR x, y")
  if(!is.null(x) & !is.null(form))
    stop("Must specify form, data OR x, y")
  if(!is.null(x))
    if(nrow(x)!=length(y))
      stop("Number of rows of x must be the same as length of y!")
  if(length(nTrain)!=length(nValid))
    stop("nTrain and nValid must have the same length!")
  n = ifelse(is.null(data), length(y), nrow(data))
  if(max(nTrain + nValid)>n)
    stop("nTrain + nValid exceeds n at some point!")
  if(length(optArgs)==0)
    stop("No arguments to optimize, length(optArgs)=0!")
  if(!is(optArgs,"list") | !all( lapply(optArgs, length)==3 ))
    stop("optArgs's arguments don't have the correct form!  Each should be a list of length 3.")
  if(!any( lapply(optArgs, function(x){
    (x[[2]] %in% c("numeric", "ordered") & length(x[[3]]==2)) |
    (x[[2]]=="categorical" & length(x[[3]])>1)}) ) )
    stop("optArgs is not of the right form!")
  #Testing functions to validate appropriate arguments

  bestError = Inf
  print("Starting cold start...")
  for(i in 1:coldStart ){
    tempArgs = randArgs(optArgs)
    samTrn = sample(n, size=nTrain[1])
    #Sample validation observations from 1:n, removing training obs
    samVal = sample((1:n)[-samTrn], size=nValid[1])
    
    #Start args with the baseArgs that you always need
    args = constArgs
    
    #Add the best estimates so far, except for the current parameter being optimized
    args = c(args, tempArgs)

    if(!is.null(form)){
      #Add the sampled data onto your args
      args = c(list(data=data[samTrn,]), args)
      args = c(list(form=form), args)

      fit = do.call(func, args)
      preds = predFunc(fit, newdata=data[samVal,])
      error = optFunc(preds, data[samVal,all.vars(form)[1]])
    } else {
      #Add the sampled x,y onto your args, make sure x and y come first
      args = c(list(y=y[samTrn]), args)
      args = c(list(x=x[samTrn,]), args)

      fit = do.call(func, args)
      #pass samVal up to Global environment so predFunc can access it, if necessary
      samVal <<- samVal
      preds = predFunc(fit, newdata=x[samVal,])
      error = optFunc(pred=preds, actual=y[samVal])
    }
    if(error<bestError){
      currArgs = tempArgs
      bestError = error
    }
  }
  print("Cold start completed, beginning main optimization...")
  
  #Main training loop
  for(epoch in 1:length(nTrain)){
    for(par in 1:length(optArgs)){
      
      currParam = optArgs[[par]][[1]]
      
      #Set the parameter values based on the desired types from optArgs
      paramVals = optArgs[[par]][[3]]
      if(optArgs[[par]][[2]]=="ordered"){
        paramVals = round(seq(paramVals[1], paramVals[2], length.out=optVals[par]))
        paramVals = unique(paramVals)
      }
      if(optArgs[[par]][[2]]=="numeric")
        paramVals = seq(paramVals[1], paramVals[2], length.out=optVals[par])
      
      errors = matrix(0, nrow=replications, ncol=length(paramVals))
      for( repl in 1:replications[epoch] ){
        samTrn = sample(n, size=nTrain[epoch])
        #Sample validation observations from 1:n, removing training obs
        samVal = sample((1:n)[-samTrn], size=nValid[epoch])
        #pass samVal up to Global environment so predFunc can access it, if necessary
        samVal <<- samVal
        for(parVal in 1:length(paramVals)){
          
          #Start args with the constArgs that you always need
          args = constArgs
          
          #Add the best estimates so far, except for the current parameter being optimized
          args = c(args, currArgs[names(currArgs)!=currParam] )

          #Add the parameter we're optimizing over
          args[[length(args)+1]] = paramVals[parVal]
          names(args)[length(args)] = currParam

          if(!is.null(form)){
            #Add the formula and sampled data onto your args
            args = c(list(data=data[samTrn,]), args)
            args = c(list(form=form), args)

            fit = do.call(func, args)
            preds = predFunc(fit, newdata=data[samVal,])
            errors[repl,parVal] = optFunc(preds, data[samVal,all.vars(form)[1]])
          } else {
            #Add the sampled x,y onto your args
            args = c(list(y=y[samTrn]), args)
            args = c(list(x=x[samTrn,]), args)

            fit = do.call(func, args)
            preds = predFunc(fit, newdata=x[samVal,])
            errors[repl,parVal] = optFunc(preds, y[samVal])
          }
        } #close parameter value loop
      } #close replication loop
      #Update currArgs with the best fit
      errors = apply(errors, 2, function(x){
        data.frame(mean=mean(x), sd=sd(x))})
      errors = do.call("rbind", errors)
      newPar = paramVals[which.min(errors[,1])]
      currArgs[currParam] = newPar
      #Update optArgs: tune parameter search as appropriate
      if(optArgs[[par]][[2]] %in% c("ordered", "numeric") ){
        oldRange = optArgs[[par]][[3]]
        len = oldRange[2] - oldRange[1]
        len = len*optRed[par]
        newRange = newPar + c(-len/2,len/2)
        
        #Move newRange if outside of original range
        if(newRange[1]<oldRange[1])
          newRange = newRange + oldRange[1] - newRange[1]
        if(newRange[2]>oldRange[2])
          newRange = newRange + oldRange[2] - newRange[2]
        optArgs[[par]][[3]] = newRange
      } else {
        #categorical variables, remove ones from search that did significantly worse.
        best = errors[which.min(errors[,1]),]
        #Assume normality, then we're testing difference in means with different variances
        zVals = sapply( 1:nrow(errors), function(i){
          (errors[i,"mean"]-best["mean"])/sqrt(errors[i,"sd"]^2+best["sd"]^2) } )
        #Remove vals with z-scores greater than 2, i.e. alpha=.05 test
        optArgs[[par]][[3]] = optArgs[[par]][[3]][zVals<2]
      }
      
      errors$paramVals = paramVals
      ggsave(paste0(Sys.info()[4],"_Param_",currParam,"_epoch_",epoch,".png")
        ,ggplot(errors, aes(x=paramVals)) + geom_point(aes(y=mean)) +
          geom_errorbar(aes(ymax=mean+2*sd, ymin=mean-2*sd)) +
          labs(x=currParam, y="Value of optFunc()") )
      print(paste("Parameter",currParam,"optimized to",paramVals[which.min(errors[,1])],"for epoch",epoch))
    } #close parameter loop
  } #close epoch loop
}
