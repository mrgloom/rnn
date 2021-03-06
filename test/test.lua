
local rnntest = {}
local precision = 1e-5
local mytester

function rnntest.Recurrent()
   local batchSize = 4
   local inputSize = 10
   local hiddenSize = 12
   local outputSize = 7
   local nSteps = 5 
   local inputModule = nn.Linear(inputSize, outputSize)
   local transferModule = nn.Sigmoid()
   -- test MLP feedback Module (because of Module:representations())
   local feedbackModule = nn.Sequential()
   feedbackModule:add(nn.Linear(outputSize, hiddenSize))
   feedbackModule:add(nn.Sigmoid())
   feedbackModule:add(nn.Linear(hiddenSize, outputSize))
   -- rho = nSteps
   local mlp = nn.Recurrent(outputSize, inputModule, feedbackModule, transferModule:clone(), nSteps)
 
   local gradOutputs, outputs = {}, {}
   -- inputs = {inputN, {inputN-1, {inputN-2, ...}}}}}
   local inputs
   local startModule = mlp.startModule:clone()
   inputModule = mlp.inputModule:clone()
   feedbackModule = mlp.feedbackModule:clone()
   
   local mlp6 = mlp:clone()
   mlp6:evaluate()
   
   mlp:zeroGradParameters()
   local mlp7 = mlp:clone()
   mlp7.rho = nSteps - 1
   local inputSequence = {}
   for step=1,nSteps do
      local input = torch.randn(batchSize, inputSize)
      inputSequence[step] = input
      local gradOutput
      if step ~= nSteps then
         -- for the sake of keeping this unit test simple,
         gradOutput = torch.zeros(batchSize, outputSize)
      else
         -- only the last step will get a gradient from the output
         gradOutput = torch.randn(batchSize, outputSize)
      end
      
      local output = mlp:forward(input)
      mlp:backward(input, gradOutput)
      
      local output6 = mlp6:forward(input)
      mytester:assertTensorEq(output, output6, 0.000001, "evaluation error "..step)
      
      local output7 = mlp7:forward(input)
      mlp7:backward(input, gradOutput)
      mytester:assertTensorEq(output, output7, 0.000001, "rho = nSteps-1 forward error "..step)

      table.insert(gradOutputs, gradOutput)
      table.insert(outputs, output:clone())
      
      if inputs then
         inputs = {input, inputs}
      else
         inputs = input
      end
   end

   local mlp4 = mlp:clone()
   local mlp5 = mlp:clone()
   
   -- backward propagate through time (BPTT)
   local gradInput = mlp:backwardThroughTime():clone()
   mlp:forget() -- test ability to forget
   mlp:zeroGradParameters()
   local foutputs = {}
   for step=1,nSteps do
      foutputs[step] = mlp:forward(inputSequence[step])
      mytester:assertTensorEq(foutputs[step], outputs[step], 0.00001, "Recurrent forget output error "..step)
      mlp:backward(input, gradOutputs[step])
   end
   local fgradInput = mlp:backwardThroughTime():clone()
   mytester:assertTensorEq(gradInput, fgradInput, 0.00001, "Recurrent forget gradInput error")
   
   mlp4.fastBackward = false
   local gradInput4 = mlp4:backwardThroughTime()
   mytester:assertTensorEq(gradInput, gradInput4, 0.000001, 'error slow vs fast backwardThroughTime')
   local mlp10 = mlp7:clone()
   mytester:assert(mlp10.inputs[1] == nil, 'recycle inputs error')
   mlp10:forget()
   mytester:assert(#mlp10.inputs == 4, 'forget inputs error')
   mytester:assert(#mlp10.outputs == 5, 'forget outputs error')
   local i = 0
   for k,v in pairs(mlp10.sharedClones) do
      i = i + 1
   end
   mytester:assert(i == 4, 'forget recurrentOutputs error')
   
   -- rho = nSteps - 1 : shouldn't update startModule
   mlp7:backwardThroughTime()
   
   local mlp2 -- this one will simulate rho = nSteps
   local outputModules = {}
   for step=1,nSteps do
      local inputModule_ = inputModule:clone()
      local outputModule = transferModule:clone()
      table.insert(outputModules, outputModule)
      inputModule_:share(inputModule, 'weight', 'gradWeight', 'bias', 'gradBias')
      if step == 1 then
         local initialModule = nn.Sequential()
         initialModule:add(inputModule_)
         initialModule:add(startModule)
         initialModule:add(outputModule)
         mlp2 = initialModule
      else
         local parallelModule = nn.ParallelTable()
         parallelModule:add(inputModule_)
         local pastModule = nn.Sequential()
         pastModule:add(mlp2)
         local feedbackModule_ = feedbackModule:clone()
         feedbackModule_:share(feedbackModule, 'weight', 'gradWeight', 'bias', 'gradBias')
         pastModule:add(feedbackModule_)
         parallelModule:add(pastModule)
         local recurrentModule = nn.Sequential()
         recurrentModule:add(parallelModule)
         recurrentModule:add(nn.CAddTable())
         recurrentModule:add(outputModule)
         mlp2 = recurrentModule
      end
   end
   
   
   local output2 = mlp2:forward(inputs)
   mlp2:zeroGradParameters()
   
   -- unlike mlp2, mlp8 will simulate rho = nSteps -1
   local mlp8 = mlp2:clone() 
   local inputModule8 = mlp8.modules[1].modules[1]
   local m = mlp8.modules[1].modules[2].modules[1].modules[1].modules[2]
   m = m.modules[1].modules[1].modules[2].modules[1].modules[1].modules[2]
   local feedbackModule8 = m.modules[2]
   local startModule8 = m.modules[1].modules[2] -- before clone
   -- unshare the intialModule:
   m.modules[1] = m.modules[1]:clone()
   m.modules[2] = m.modules[2]:clone()
   mlp8:backward(inputs, gradOutputs[#gradOutputs])
   
   local gradInput2 = mlp2:backward(inputs, gradOutputs[#gradOutputs])
   for step=1,nSteps-1 do
      gradInput2 = gradInput2[2]
   end   
   
   mytester:assertTensorEq(gradInput, gradInput2, 0.000001, "recurrent gradInput")
   mytester:assertTensorEq(outputs[#outputs], output2, 0.000001, "recurrent output")
   for step=1,nSteps do
      local output, outputModule = outputs[step], outputModules[step]
      mytester:assertTensorEq(output, outputModule.output, 0.000001, "recurrent output step="..step)
   end
   
   local mlp3 = nn.Sequential()
   -- contains params and grads of mlp2 (the MLP version of the Recurrent)
   mlp3:add(startModule):add(inputModule):add(feedbackModule)
   local params2, gradParams2 = mlp3:parameters()
   local params, gradParams = mlp:parameters()
   mytester:assert(#params2 == #params, 'missing parameters')
   mytester:assert(#gradParams == #params, 'missing gradParameters')
   mytester:assert(#gradParams2 == #params, 'missing gradParameters2')
   
   for i=1,#params do
      if i > 1 then
         gradParams2[i]:div(nSteps)
      end
      mytester:assertTensorEq(gradParams[i], gradParams2[i], 0.000001, 'gradParameter error ' .. i)
   end
   
   local mlp9 = nn.Sequential()
   -- contains params and grads of mlp8
   mlp9:add(startModule8):add(inputModule8):add(feedbackModule8)
   local params9, gradParams9 = mlp9:parameters()
   local params7, gradParams7 = mlp7:parameters()
   mytester:assert(#params9 == #params7, 'missing parameters')
   mytester:assert(#gradParams7 == #params7, 'missing gradParameters')
   for i=1,#params do
      if i > 1 then
         gradParams9[i]:div(nSteps-1)
      end
      mytester:assertTensorEq(gradParams7[i], gradParams9[i], 0.00001, 'gradParameter error ' .. i)
   end
   
   -- already called backwardThroughTime()
   mlp:updateParameters(0.1) 
   mlp4:updateParameters(0.1) 
   
   local params4 = mlp4:parameters()
   local params5 = mlp5:parameters()
   local params = mlp:parameters()
   mytester:assert(#params4 == #params, 'missing parameters')
   mytester:assert(#params5 == #params, 'missing parameters')
   for i=1,#params do
      mytester:assertTensorEq(params[i], params4[i], 0.000001, 'backwardThroughTime error ' .. i)
      mytester:assertTensorNe(params[i], params5[i], 0.0000000001, 'backwardThroughTime error ' .. i)
   end
   
   -- should call backwardUpdateThroughTime()
   mlp5:updateParameters(0.1)
   
   local params5 = mlp5:parameters()
   local params = mlp:parameters()
   mytester:assert(#params5 == #params, 'missing parameters')
   for i=1,#params do
      mytester:assertTensorEq(params[i], params5[i], 0.000001, 'backwardUpdateThroughTime error ' .. i)
   end
   
   mlp:forget()
   mlp:zeroGradParameters()
   local rnn = mlp:float()
   local outputs2 = {}
   for step=1,nSteps do
      rnn:forward(inputSequence[step]:float())
      rnn:backward(inputSequence[step]:float(), gradOutputs[step]:float())
   end
   local gradInput2 = rnn:backwardThroughTime()
end

function rnntest.Recurrent_oneElement()
   -- test sequence of one element
   local x = torch.rand(200)
   local target = torch.rand(2)

   local rho = 5
   local hiddenSize = 100
   -- RNN
   local r = nn.Recurrent(
     hiddenSize, nn.Linear(200,hiddenSize), 
     nn.Linear(hiddenSize, hiddenSize), nn.Sigmoid(), 
     rho
   )

   local seq = nn.Sequential()
   seq:add(r)
   seq:add(nn.Linear(hiddenSize, 2))

   local criterion = nn.MSECriterion()

   local output = seq:forward(x)
   local err = criterion:forward(output,target)
   local gradOutput = criterion:backward(output,target)
   
   seq:backward(x,gradOutput)
   seq:updateParameters(0.01)
end

function rnntest.Recurrent_TestTable()
   -- Set up RNN where internal state is a table.
   -- Trivial example is same RNN from rnntest.Recurrent test
   -- but all layers are duplicated
   local batchSize = 4
   local inputSize = 10
   local hiddenSize = 12
   local outputSize = 7
   local nSteps = 5 
   local inputModule = nn.Linear(inputSize, outputSize)
   local transferModule = nn.Sigmoid()
   local learningRate = 0.1
   -- test MLP feedback Module
   local feedbackModule = nn.Sequential()
   feedbackModule:add(nn.Linear(outputSize, hiddenSize))
   feedbackModule:add(nn.Sigmoid())
   feedbackModule:add(nn.Linear(hiddenSize, outputSize))
   -- rho = nSteps
   local mlp = nn.Recurrent(
      nn.ParallelTable()
         :add(nn.Add(outputSize))
         :add(nn.Add(outputSize)),
      nn.ParallelTable()
         :add(inputModule:clone())
         :add(inputModule:clone()),
      nn.ParallelTable()
         :add(feedbackModule:clone())
         :add(feedbackModule:clone()),
      nn.ParallelTable()
         :add(transferModule:clone())
         :add(transferModule:clone()),
      nSteps,
      nn.ParallelTable()
         :add(nn.CAddTable())
         :add(nn.CAddTable())
   )

   local input = torch.randn(batchSize, inputSize)
   local err = torch.randn(batchSize, outputSize)
   for i=1,10 do
      mlp:forward{input, input:clone()}
      mlp:backward({input, input:clone()}, {err, err:clone()})
   end
   mlp:backwardThroughTime(learningRate)
end

function rnntest.LSTM()
   local batchSize = math.random(1,2)
   local inputSize = math.random(3,4)
   local outputSize = math.random(5,6)
   local nStep = 3
   local input = {}
   local gradOutput = {}
   for step=1,nStep do
      input[step] = torch.randn(batchSize, inputSize)
      if step == nStep then
         -- for the sake of keeping this unit test simple,
         gradOutput[step] = torch.randn(batchSize, outputSize)
      else
         -- only the last step will get a gradient from the output
         gradOutput[step] = torch.zeros(batchSize, outputSize)
      end
   end
   local lstm = nn.LSTM(inputSize, outputSize)
   
   -- we will use this to build an LSTM step by step (with shared params)
   local lstmStep = lstm.recurrentModule:clone()
   
   -- forward/backward through LSTM
   local output = {}
   lstm:zeroGradParameters()
   for step=1,nStep do
      output[step] = lstm:forward(input[step])
      assert(torch.isTensor(input[step]))
      lstm:backward(input[step], gradOutput[step], 1)
   end   
   local gradInput = lstm:backwardThroughTime()
   
   local mlp2 -- this one will simulate rho = nSteps
   local inputs
   for step=1,nStep do
      -- iteratively build an LSTM out of non-recurrent components
      local lstm = lstmStep:clone()
      lstm:share(lstmStep, 'weight', 'gradWeight', 'bias', 'gradBias')
      if step == 1 then
         mlp2 = lstm
      else
         local rnn = nn.Sequential()
         local para = nn.ParallelTable()
         para:add(nn.Identity()):add(mlp2)
         rnn:add(para)
         rnn:add(nn.FlattenTable())
         rnn:add(lstm)
         mlp2 = rnn
      end
      
      -- prepare inputs for mlp2
      if inputs then
         inputs = {input[step], inputs}
      else
         inputs = {input[step], torch.zeros(batchSize, outputSize), torch.zeros(batchSize, outputSize)}
      end
   end
   mlp2:add(nn.SelectTable(1)) --just output the output (not cell)
   local output2 = mlp2:forward(inputs)
   
   mlp2:zeroGradParameters()
   local gradInput2 = mlp2:backward(inputs, gradOutput[nStep], 1/nStep)
   mytester:assertTensorEq(gradInput2[2][2][1], gradInput, 0.00001, "LSTM gradInput error")
   mytester:assertTensorEq(output[nStep], output2, 0.00001, "LSTM output error")
   
   local params, gradParams = lstm:parameters()
   local params2, gradParams2 = lstmStep:parameters()
   mytester:assert(#params == #params2, "LSTM parameters error "..#params.." ~= "..#params2)
   for i, gradParam in ipairs(gradParams) do
      local gradParam2 = gradParams2[i]
      mytester:assertTensorEq(gradParam, gradParam2, 0.000001, 
         "LSTM gradParam "..i.." error "..tostring(gradParam).." "..tostring(gradParam2))
   end
   
   gradParams = lstm.recursiveCopy(nil, gradParams)
   gradInput = gradInput:clone()
   mytester:assert(lstm.zeroTensor:sum() == 0, "zeroTensor error")
   lstm:forget()
   output = lstm.recursiveCopy(nil, output)
   local output3 = {}
   lstm:zeroGradParameters()
   for step=1,nStep do
      output3[step] = lstm:forward(input[step])
      lstm:backward(input[step], gradOutput[step], 1)
   end   
   local gradInput3 = lstm:updateGradInputThroughTime()
   lstm:accGradParametersThroughTime()
   
   mytester:assert(#output == #output3, "LSTM output size error")
   for i,output in ipairs(output) do
      mytester:assertTensorEq(output, output3[i], 0.00001, "LSTM forget (updateOutput) error "..i)
   end
   
   mytester:assertTensorEq(gradInput, gradInput3, 0.00001, "LSTM updateGradInputThroughTime error")
   --if true then return end
   local params3, gradParams3 = lstm:parameters()
   mytester:assert(#params == #params3, "LSTM parameters error "..#params.." ~= "..#params3)
   for i, gradParam in ipairs(gradParams) do
      local gradParam3 = gradParams3[i]
      mytester:assertTensorEq(gradParam, gradParam3, 0.000001, 
         "LSTM gradParam "..i.." error "..tostring(gradParam).." "..tostring(gradParam3))
   end
end

function rnntest.Sequencer()
   local batchSize = 4
   local inputSize = 10
   local outputSize = 7
   local nSteps = 5 
   
   -- test with recurrent module
   local inputModule = nn.Euclidean(inputSize, outputSize)
   local transferModule = nn.Sigmoid()
   -- test MLP feedback Module (because of Module:representations())
   local feedbackModule = nn.Euclidean(outputSize, outputSize)
   -- rho = nSteps
   local rnn = nn.Recurrent(outputSize, inputModule, feedbackModule, transferModule, nSteps)
   local rnn2 = rnn:clone()
   
   local inputs, outputs, gradOutputs = {}, {}, {}
   for step=1,nSteps do
      inputs[step] = torch.randn(batchSize, inputSize)
      outputs[step] = rnn:forward(inputs[step]):clone()
      gradOutputs[step] = torch.randn(batchSize, outputSize)
      rnn:backward(inputs[step], gradOutputs[step])
   end
   rnn:backwardThroughTime()
   
   local rnn3 = nn.Sequencer(rnn2)
   local outputs3 = rnn3:forward(inputs)
   local gradInputs3 = rnn3:backward(inputs, gradOutputs)
   mytester:assert(#outputs3 == #outputs, "Sequencer output size err")
   mytester:assert(#gradInputs3 == #rnn.gradInputs, "Sequencer gradInputs size err")
   for step,output in ipairs(outputs) do
      mytester:assertTensorEq(outputs3[step], output, 0.00001, "Sequencer output "..step)
      mytester:assertTensorEq(gradInputs3[step], rnn.gradInputs[step], 0.00001, "Sequencer gradInputs "..step)
   end
   
   -- test in evaluation mode
   rnn3:evaluate()
   local outputs4 = rnn3:forward(inputs)
   local outputs4_ = _.map(outputs4, function(k,v) return v:clone() end)
   mytester:assert(#outputs4 == #outputs, "Sequencer evaluate output size err")
   for step,output in ipairs(outputs) do
      mytester:assertTensorEq(outputs4[step], output, 0.00001, "Sequencer evaluate output "..step)
   end
   local inputs5 = _.clone(inputs)
   table.remove(inputs5, nSteps) -- remove last input
   local outputs5 = rnn3:forward(inputs5)
   mytester:assert(#outputs5 == #outputs - 1, "Sequencer evaluate -1 output size err")
   for step,output in ipairs(outputs5) do
      mytester:assertTensorEq(outputs[step], output, 0.00001, "Sequencer evaluate -1 output "..step)
   end
   
   -- test evaluation with remember 
   rnn3:evaluate()
   rnn3:forget() -- flush out current buffers.
   rnn3:remember()
   local inputsA, inputsB = {inputs[1],inputs[2],inputs[3]}, {inputs[4],inputs[5]}
   local outputsA = _.map(rnn3:forward(inputsA), function(k,v) return v:clone() end)
   local outputsB = rnn3:forward(inputsB)
   mytester:assert(#outputsA == 3, "Sequencer evaluate-remember output size err A")
   mytester:assert(#outputsB == 2, "Sequencer evaluate-remember output size err B")
   local outputsAB = {unpack(outputsA)}
   outputsAB[4], outputsAB[5] = unpack(outputsB)
   for step,output in ipairs(outputs4_) do
      mytester:assertTensorEq(outputsAB[step], output, 0.00001, "Sequencer evaluate-remember output "..step)
   end
   
   -- test with non-recurrent module
   local linear = nn.Euclidean(inputSize, outputSize)
   local seq, outputs, gradInputs
   for k=1,3 do
      outputs, gradInputs = {}, {}
      linear:zeroGradParameters()
      local clone = linear:clone()
      for step=1,nSteps do
         outputs[step] = linear:forward(inputs[step]):clone()
         gradInputs[step] = linear:backward(inputs[step], gradOutputs[step]):clone()
      end
      
      seq = nn.Sequencer(clone)
      local outputs2 = seq:forward(inputs)
      local gradInputs2 = seq:backward(inputs, gradOutputs)
      
      mytester:assert(#outputs2 == #outputs, "Sequencer output size err")
      mytester:assert(#gradInputs2 == #gradInputs, "Sequencer gradInputs size err")
      for step,output in ipairs(outputs) do
         mytester:assertTensorEq(outputs2[step], output, 0.00001, "Sequencer output "..step)
         mytester:assertTensorEq(gradInputs2[step], gradInputs[step], 0.00001, "Sequencer gradInputs "..step)
      end
   end
   
   mytester:assertError(function()
      local mlp = nn.Sequential()
      mlp:add(rnn)
      local seq = nn.Sequencer(mlp)
   end, "Sequencer non-recurrent mixed with recurrent error error")
   
   local inputs3, gradOutputs3 = {}, {}
   for i=1,#inputs do
      inputs3[i] = inputs[i]:float()
      gradOutputs3[i] = gradOutputs[i]:float()
   end
   local seq3 = seq:float()
   local outputs3 = seq:forward(inputs3)
   local gradInputs3 = seq:backward(inputs3, gradOutputs3)
   
   -- test for zeroGradParameters
   local seq = nn.Sequencer(nn.Linear(inputSize,outputSize))
   seq:zeroGradParameters()
   seq:forward(inputs)
   seq:backward(inputs, gradOutputs)
   local params, gradParams = seq:parameters()
   for i,gradParam in ipairs(gradParams) do
      mytester:assert(gradParam:sum() ~= 0, 0.000001, "Sequencer:backward err "..i)
   end
   local param, gradParam = seq:getParameters()
   seq:zeroGradParameters()
   mytester:assert(gradParam:sum() == 0, 0.000001, "Sequencer:getParameters err")
   local params, gradParams = seq:parameters()
   for i,gradParam in ipairs(gradParams) do
      mytester:assert(gradParam:sum() == 0, 0.000001, "Sequencer:zeroGradParameters err "..i)
   end
   
   -- test with LSTM
   local lstm = nn.LSTM(inputSize, outputSize)
   local lstm2 = lstm:clone()
   
   local inputs, outputs, gradOutputs = {}, {}, {}
   for step=1,nSteps do
      inputs[step] = torch.randn(batchSize, inputSize)
      outputs[step] = lstm:forward(inputs[step])
      gradOutputs[step] = torch.randn(batchSize, outputSize)
      lstm:backward(inputs[step], gradOutputs[step])
   end
   lstm:backwardThroughTime()
   
   local lstm3 = nn.Sequencer(lstm2)
   local outputs3 = lstm3:forward(inputs)
   local gradInputs3 = lstm3:backward(inputs, gradOutputs)
   mytester:assert(#outputs3 == #outputs, "Sequencer LSTM output size err")
   mytester:assert(#gradInputs3 == #rnn.gradInputs, "Sequencer LSTM gradInputs size err")
   for step,output in ipairs(outputs) do
      mytester:assertTensorEq(outputs3[step], output, 0.00001, "Sequencer LSTM output "..step)
      mytester:assertTensorEq(gradInputs3[step], lstm.gradInputs[step], 0.00001, "Sequencer LSTM gradInputs "..step)
   end
end

function rnntest.Repeater()
   local batchSize = 4
   local inputSize = 10
   local outputSize = 7
   local nSteps = 5 
   local inputModule = nn.Linear(inputSize, outputSize)
   local transferModule = nn.Sigmoid()
   -- test MLP feedback Module (because of Module:representations())
   local feedbackModule = nn.Linear(outputSize, outputSize)
   -- rho = nSteps
   local rnn = nn.Recurrent(outputSize, inputModule, feedbackModule, transferModule, nSteps)
   local rnn2 = rnn:clone()
   
   local inputs, outputs, gradOutputs = {}, {}, {}
   local input = torch.randn(batchSize, inputSize)
   for step=1,nSteps do
      outputs[step] = rnn:forward(input)
      gradOutputs[step] = torch.randn(batchSize, outputSize)
      rnn:backward(input, gradOutputs[step])
   end
   rnn:backwardThroughTime()
   
   local rnn3 = nn.Repeater(rnn2, nSteps)
   local outputs3 = rnn3:forward(input)
   local gradInput3 = rnn3:backward(input, gradOutputs)
   mytester:assert(#outputs3 == #outputs, "Repeater output size err")
   mytester:assert(#outputs3 == #rnn.gradInputs, "Repeater gradInputs size err")
   local gradInput = rnn.gradInputs[1]:clone():zero()
   for step,output in ipairs(outputs) do
      mytester:assertTensorEq(outputs3[step], output, 0.00001, "Sequencer output "..step)
      gradInput:add(rnn.gradInputs[step])
   end
   mytester:assertTensorEq(gradInput3, gradInput, 0.00001, "Repeater gradInput err")
end

function rnntest.SequencerCriterion()
   local batchSize = 4
   local inputSize = 10
   local outputSize = 7
   local nSteps = 5  
   local criterion = nn.ClassNLLCriterion()
   local sc = nn.SequencerCriterion(criterion)
   local input = {}
   local target = {}
   local err2 = 0
   local gradInput2 = {}
   for i=1,nSteps do
      input[i] = torch.randn(batchSize, inputSize)
      target[i] = torch.randperm(inputSize):narrow(1,1,batchSize)
      err2 = err2 + criterion:forward(input[i], target[i])
      gradInput2[i] = criterion:backward(input[i], target[i]):clone()
   end
   local err = sc:forward(input, target)
   mytester:asserteq(err, err2, 0.000001, "SequencerCriterion forward err") 
   local gradInput = sc:backward(input, target)
   for i=1,nSteps do
      mytester:assertTensorEq(gradInput[i], gradInput2[i], 0.000001, "SequencerCriterion backward err "..i)
   end
end


function rnn.test(tests)
   mytester = torch.Tester()
   mytester:add(rnntest)
   math.randomseed(os.time())
   mytester:run(tests)
end
