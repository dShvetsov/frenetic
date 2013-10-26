open NetKAT_Types

let policy_parse (p : string) : NetKAT_Types.policy =
  NetKAT_Parser.program NetKAT_Lexer.token (Lexing.from_string p)

TEST "the simplest test" =
  let open NetKAT_Automaton in
  let pol = policy_parse "filter port = 1; 0@0 => 1@1" in
  let re  = regex_of_policy pol in
  match re with 
    | Char(_) -> true
    | _       -> false

TEST "the simplest test II" =
  let open NetKAT_Automaton in
  let pol = policy_parse "1@1 => 2@2; 0@0 => 1@1" in
  let re  = regex_of_policy pol in
  match re with 
    | Cat(Char(_), Char(_)) -> true
    | _                     -> false

