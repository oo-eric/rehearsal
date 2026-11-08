// Example song so the app runs out of the box. build.py writes app/songs.js, which
// loads after this file and replaces it.
window.SONGS = [
 {
  "slug": "demo-12-bar-blues",
  "title": "Demo: 12-Bar Blues",
  "bpm": 96,
  "bpmSource": "example",
  "key": "A",
  "sections": [
   {
    "name": "Intro",
    "from": 1,
    "to": 4,
    "rows": [
     {
      "bars": [
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "D",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "E",
         "b": 4
        }
       ]
      ],
      "lyrics": [],
      "note": "count it off"
     }
    ],
    "notes": []
   },
   {
    "name": "Verse 1",
    "from": 5,
    "to": 16,
    "rows": [
     {
      "bars": [
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ]
      ],
      "lyrics": [
       "This is a demo song, it ships with the app"
      ],
      "note": ""
     },
     {
      "bars": [
       [
        {
         "c": "D",
         "b": 4
        }
       ],
       [
        {
         "c": "D",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ]
      ],
      "lyrics": [
       "Run build.py and your own charts replace it"
      ],
      "note": ""
     },
     {
      "bars": [
       [
        {
         "c": "E",
         "b": 4
        }
       ],
       [
        {
         "c": "D",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 2
        },
        {
         "c": "E",
         "b": 2
        }
       ]
      ],
      "lyrics": [
       "Lyrics sit under each row of four bars"
      ],
      "note": ""
     }
    ],
    "notes": []
   },
   {
    "name": "Verse 2",
    "from": 17,
    "to": 28,
    "rows": [
     {
      "bars": [
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ]
      ],
      "lyrics": [
       "Right arrow moves a line, ] jumps a section"
      ],
      "note": ""
     },
     {
      "bars": [
       [
        {
         "c": "D",
         "b": 4
        }
       ],
       [
        {
         "c": "D",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ]
      ],
      "lyrics": [
       "P starts tempo mode with a one-bar count-in"
      ],
      "note": ""
     },
     {
      "bars": [
       [
        {
         "c": "E",
         "b": 4
        }
       ],
       [
        {
         "c": "D",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "E",
         "b": 4
        }
       ]
      ],
      "lyrics": [
       "Split bars show both chords, like the last one up there"
      ],
      "note": ""
     }
    ],
    "notes": []
   },
   {
    "name": "Outro",
    "from": 29,
    "to": 32,
    "rows": [
     {
      "bars": [
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "D",
         "b": 4
        }
       ],
       [
        {
         "c": "A",
         "b": 4
        }
       ],
       [
        {
         "c": "",
         "b": 4
        }
       ]
      ],
      "lyrics": [],
      "note": "ring out"
     }
    ],
    "notes": []
   }
  ]
 }
];
