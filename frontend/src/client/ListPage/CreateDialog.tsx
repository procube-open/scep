import React, { useState, ChangeEvent } from 'react';
import {
  Dialog,
  DialogTitle,
  DialogContent,
  TextField,
  DialogActions,
  Button
} from '@mui/material';
import {
  useTranslate,
  useDataProvider,
  useNotify,
  useRefresh
} from 'react-admin';

interface CreateDialogProps {
  open: boolean;
  handleClose: () => void;
}

const CreateDialog: React.FC<CreateDialogProps> = ({ open, handleClose }) => {
  const [userId, setUserId] = useState<string>('');
  const [attributes, setAttributes] = useState<string>('');
  const [userIdError, setUserIdError] = useState<boolean>(false);
  const [attributesError, setAttributesError] = useState<boolean>(false);
  const [attributesParseError, setAttributesParseError] = useState<boolean>(false);
  const translate = useTranslate();
  const dataProvider = useDataProvider();
  const notify = useNotify();
  const refresh = useRefresh();

  const handleUserIdChange = (event: ChangeEvent<HTMLInputElement>) => {
    setUserId(event.target.value);
    if (event.target.value.trim() === '') {
      setUserIdError(true);
    } else {
      setUserIdError(false);
    }
  };

  const handleAttributesChange = (event: ChangeEvent<HTMLInputElement>) => {
    setAttributes(event.target.value);
    if (event.target.value.trim() === '') {
      setAttributesError(true);
    } else {
      setAttributesError(false);
    }
    try {
      JSON.parse(event.target.value);
      setAttributesParseError(false);
    } catch (e) {
      setAttributesParseError(true);
    }
  };

  const handleSave = () => {
    let isValid = true;
    if (userId.trim() === '') {
      setUserIdError(true);
      isValid = false;
    } else {
      setUserIdError(false);
    }

    if (attributes.trim() === '') {
      setAttributesError(true);
      isValid = false;
    } else {
      setAttributesError(false);
    }

    try {
      JSON.parse(attributes);
      setAttributesParseError(false);
    } catch (e) {
      setAttributesParseError(true);
      isValid = false;
    }

    if (isValid) {
      dataProvider.createOne('client', { uid: userId, attributes: attributes })
        .then(() => {
          notify('client.created', { type: 'success' });
          handleClose();
          refresh();
        })
        .catch((e: Error) => {
          notify(`Error: ${e.message}`, { type: 'error' });
        });
    }
  };

  return (
    <Dialog open={open} onClose={handleClose} fullWidth maxWidth={"md"}>
      <DialogTitle>{translate("client.dialog.title")}</DialogTitle>
      <DialogContent>
        <TextField
          autoFocus
          margin="dense"
          id="userId"
          label={translate("client.fields.uid")}
          type="text"
          fullWidth
          value={userId}
          onChange={handleUserIdChange}
          error={userIdError}
          helperText={userIdError ? translate("error.requiredError") : ''}
        />
        <TextField
          margin="dense"
          id="attributes"
          label={translate("client.fields.attributes")}
          type="text"
          fullWidth
          value={attributes}
          onChange={handleAttributesChange}
          error={attributesError || attributesParseError}
          helperText={attributesError ? translate("error.requiredError") : attributesParseError ? translate("error.parseError") : ''}
        />
      </DialogContent>
      <DialogActions>
        <Button onClick={handleClose} color="primary">
          {translate("ra.action.cancel")}
        </Button>
        <Button onClick={handleSave} color="primary">
          {translate("ra.action.save")}
        </Button>
      </DialogActions>
    </Dialog>
  );
};


export default CreateDialog;
