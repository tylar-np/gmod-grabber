-- Server hosts can place a file like this somewhere in lua/autorun/client/
-- to add custom repositories to Grabber for their users.
-- MAKE SURE THAT you call grabber.AddRepository in the frame AFTER
-- InitPostEntity runs (e.g. put it in a timer.Simple(0) callback:

hook.Add("InitPostEntity", "ExampleIPE", function()
    timer.Simple(0, function()
        grabber.AddRepository("grabberlua", "tjb2640", "grabber-gmod", "main", "expression2")
    end)
end)
